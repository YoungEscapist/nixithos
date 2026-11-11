# The scripted halves of nixpkgs' modules, for a nixpkgs that no longer has
# them (26.11 on: see `noScripted` in ../../../parts.nix).  Until 26.05 the
# modules of LUKS, LVM, the file systems and the console each had two halves:
# units for systemd's initrd, and commands for the hooks of the scripted
# stage 1.  The second kind is what ../stage-1.nix runs; it is kept here, as
# it was in nixos-26.05.
#
# Not brought back (their modules are large, and nothing here tests them):
# the scripted halves of ZFS, bcachefs, clevis, iSCSI and multipath roots,
# Plymouth, and the network, SSH and OpenVPN in the initrd.  They work on
# the 26.05 base.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib) mkIf mkMerge mkBefore;

  inInitrd = fs: config.boot.initrd.supportedFilesystems.${fs} or false;
  inSystem = fs: config.boot.supportedFilesystems.${fs} or false;

  console = config.console;
  isUnicode = config.i18n.defaultCharset == "UTF-8" || console.useXkbConfig;
  consoleEnv =
    kbd:
    pkgs.buildEnv {
      name = "console-env";
      paths = [ kbd ] ++ console.packages;
      pathsToLink = [
        "/share/consolefonts"
        "/share/consoletrans"
        "/share/keymaps"
        "/share/unimaps"
      ];
    };
  optimizedKeymap =
    pkgs.runCommand "keymap"
      {
        nativeBuildInputs = [ pkgs.buildPackages.kbd ];
        LOADKEYS_KEYMAP_PATH = "${consoleEnv pkgs.kbd}/share/keymaps/**";
        preferLocalBuild = true;
      }
      ''
        loadkeys -b ${lib.optionalString isUnicode "-u"} "${console.keyMap}" > $out
      '';

  lvm = config.services.lvm;
  mount_cifs = "${pkgs.cifs-utils}/bin/mount.cifs";
in

{
  imports = [
    ./luksroot.nix
    ./encrypted-devices.nix
  ];

  options.boot.initrd.systemd.enable = lib.mkOption {
    type = lib.types.bool;
    default = false;
    internal = true;
    description = "Whether stage 1 is systemd's: never, here.";
  };

  config = mkMerge [
    # --- the console (config/console.nix)
    (mkIf console.enable {
      boot.initrd.preLVMCommands = mkBefore ''
        kbd_mode ${if isUnicode then "-u" else "-a"} -C /dev/console
        printf "\033%%${if isUnicode then "G" else "@"}" >> /dev/console
        loadkmap < ${optimizedKeymap}

        ${lib.optionalString (console.earlySetup && console.font != null) ''
          setfont -C /dev/console $extraUtils/share/consolefonts/font.psf
        ''}
      '';
    })
    (mkIf (console.enable && console.earlySetup && console.font != null) {
      boot.initrd.extraUtilsCommands = ''
        mkdir -p $out/share/consolefonts
        ${
          if lib.substring 0 1 console.font == "/" then
            ''
              font="${console.font}"
            ''
          else
            ''
              font="$(echo ${consoleEnv pkgs.kbd}/share/consolefonts/${console.font}.*)"
            ''
        }
        if [[ $font == *.gz ]]; then
          gzip -cd $font > $out/share/consolefonts/font.psf
        else
          cp -L $font $out/share/consolefonts/font.psf
        fi
      '';
    })

    # --- the file systems (tasks/filesystems/*.nix)
    {
      # (always, as with the scripted stage 1 of 26.05: the fsck of the root
      # and the modules of a disk moved to another machine)
      system.fsPackages = [ pkgs.e2fsprogs ];
      boot.initrd.availableKernelModules = [
        "ext2"
        "ext4"
      ];
      boot.initrd.extraUtilsCommands = ''
        # Copy e2fsck and friends.
        copy_bin_and_libs ${pkgs.e2fsprogs}/sbin/e2fsck
        copy_bin_and_libs ${pkgs.e2fsprogs}/sbin/tune2fs
        ln -sv e2fsck $out/bin/fsck.ext2
        ln -sv e2fsck $out/bin/fsck.ext3
        ln -sv e2fsck $out/bin/fsck.ext4
      '';
    }
    (mkIf (inInitrd "btrfs") {
      boot.initrd.extraUtilsCommands = ''
        copy_bin_and_libs ${pkgs.btrfs-progs}/bin/btrfs
        ln -sv btrfs $out/bin/btrfsck
        ln -sv btrfsck $out/bin/fsck.btrfs
      '';
      boot.initrd.extraUtilsCommandsTest = ''
        $out/bin/btrfs --version
      '';
      boot.initrd.postDeviceCommands = ''
        btrfs device scan
      '';
    })
    (mkIf (inInitrd "vfat") {
      boot.initrd.extraUtilsCommands = ''
        copy_bin_and_libs ${pkgs.dosfstools}/sbin/dosfsck
        ln -sv dosfsck $out/bin/fsck.vfat
      '';
    })
    (mkIf (inInitrd "xfs") {
      boot.initrd.extraUtilsCommands = ''
        copy_bin_and_libs ${pkgs.xfsprogs.bin}/bin/fsck.xfs
        copy_bin_and_libs ${pkgs.xfsprogs.bin}/bin/xfs_repair
      '';
      # Trick just to set 'sh' after the extraUtils nuke-refs.
      boot.initrd.extraUtilsCommandsTest = ''
        sed -i -e 's,^#!.*,#!'$out/bin/sh, $out/bin/fsck.xfs
      '';
    })
    (mkIf (inInitrd "f2fs") {
      boot.initrd.extraUtilsCommands = ''
        copy_bin_and_libs ${pkgs.f2fs-tools}/sbin/fsck.f2fs
      '';
    })
    (mkIf (inInitrd "jfs") {
      boot.initrd.extraUtilsCommands = ''
        copy_bin_and_libs ${lib.getBin pkgs.jfsutils}/sbin/fsck.jfs
      '';
    })
    (mkIf (inInitrd "cifs") {
      boot.initrd.extraUtilsCommands = ''
        copy_bin_and_libs ${mount_cifs}
      '';
    })
    (mkIf (inInitrd "unionfs-fuse") {
      boot.initrd.extraUtilsCommands = ''
        copy_bin_and_libs ${pkgs.fuse}/sbin/mount.fuse
        copy_bin_and_libs ${pkgs.unionfs-fuse}/bin/unionfs
        substitute ${pkgs.unionfs-fuse}/sbin/mount.unionfs-fuse $out/bin/mount.unionfs-fuse \
          --replace '${pkgs.bash}/bin/bash' /bin/sh \
          --replace '${pkgs.fuse}/sbin' /bin \
          --replace '${pkgs.unionfs-fuse}/bin' /bin
        chmod +x $out/bin/mount.unionfs-fuse
      '';
      boot.initrd.postDeviceCommands = ''
        # Hacky!!! fuse hard-codes the path to mount
        mkdir -p /nix/store/eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee-${pkgs.util-linux.name}-bin/bin
        ln -s $(which mount) /nix/store/eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee-${pkgs.util-linux.name}-bin/bin
        ln -s $(which umount) /nix/store/eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee-${pkgs.util-linux.name}-bin/bin
      '';
    })

    # --- LVM thin pools and VDO (tasks/lvm.nix)
    (mkIf lvm.boot.thin.enable {
      boot.initrd.extraUtilsCommands = ''
        for BIN in ${pkgs.thin-provisioning-tools}/bin/*; do
          copy_bin_and_libs $BIN
        done
      '';
      boot.initrd.extraUtilsCommandsTest = ''
        ls ${pkgs.thin-provisioning-tools}/bin/ | grep -v pdata_tools | while read BIN; do
          $out/bin/$(basename $BIN) --help > /dev/null
        done
      '';
    })
    (mkIf lvm.boot.vdo.enable {
      boot.initrd.extraUtilsCommands = ''
        ls ${pkgs.vdo}/bin/ | while read BIN; do
          copy_bin_and_libs ${pkgs.vdo}/bin/$BIN
        done
        substituteInPlace $out/bin/vdorecover --replace "${pkgs.bash}/bin/bash" "/bin/sh"
        substituteInPlace $out/bin/adaptlvm --replace "${pkgs.bash}/bin/bash" "/bin/sh"
      '';
      boot.initrd.extraUtilsCommandsTest = ''
        exclude='adaptlvm|vdorecover|vdocalculatesize'
        ls ${pkgs.vdo}/bin/ | grep -vE "($exclude)" | while read BIN; do
          $out/bin/$(basename $BIN) --help > /dev/null
        done
      '';
    })

    # --- software RAID (tasks/swraid.nix)
    (mkIf config.boot.swraid.enable {
      boot.initrd.extraUdevRulesCommands = ''
        cp -v ${pkgs.mdadm}/lib/udev/rules.d/*.rules $out/
      '';
      boot.initrd.extraUtilsCommands = ''
        # Add RAID mdadm tool.
        copy_bin_and_libs ${pkgs.mdadm}/sbin/mdadm
        copy_bin_and_libs ${pkgs.mdadm}/sbin/mdmon
      '';
      boot.initrd.extraUtilsCommandsTest = ''
        $out/bin/mdadm --version
      '';
    })

    # --- bcache (tasks/bcache.nix)
    (mkIf config.boot.bcache.enable {
      boot.initrd.extraUdevRulesCommands = ''
        cp -v ${pkgs.bcache-tools}/lib/udev/rules.d/*.rules $out/
      '';
    })
  ];
}
