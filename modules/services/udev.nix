# Device management with eudev.
#
# The option interface (`services.udev.*`, `hardware.firmware`, …) is
# upstream's: nixos/modules/services/hardware/udev.nix is imported
# options-only.  The implementation below follows it closely, minus the parts
# that need systemd's udev (`udevadm verify`, `systemd-hwdb`).
#
# systemd.link(5) files (`systemd.network.links`, which is how NixOS sets an
# interface's MTU and MAC address, scripted networking included) are written
# where systemd-udevd would read them, and applied by unit-link, which the
# rules below run: eudev knows nothing of them.
{
  config,
  lib,
  pkgs,
  utils,
  ...
}:

let
  cfg = config.services.udev;
  udev = cfg.package;

  unitLink = lib.getExe pkgs.nixithos.unitLink;
  # before eudev's own naming (80-net-name-slot.rules), which keeps a name
  # that is set already
  linkRules = pkgs.writeTextFile {
    name = "unit-link-rules";
    destination = "/etc/udev/rules.d/75-unit-link.rules";
    text = ''
      SUBSYSTEM!="net", GOTO="unit_link_end"
      ACTION=="add", NAME=="", IMPORT{program}="${unitLink} name $env{INTERFACE}"
      ACTION=="add", NAME=="", ENV{UNIT_LINK_NAME}=="?*", NAME="$env{UNIT_LINK_NAME}"
      ACTION=="add|move", RUN+="${unitLink} apply $env{INTERFACE}"
      LABEL="unit_link_end"
    '';
  };
  # A name that nothing assigned in this event is kept, as systemd-udevd does
  # (NamePolicy=keep): it is what later rules match with NAME== (NixOS's own
  # 99-ipv6-privacy-extensions.rules does, per interface).  After eudev's
  # 80-net-name-slot.rules, which only names what is unnamed.
  linkKeepRules = pkgs.writeTextFile {
    name = "unit-link-keep-rules";
    destination = "/etc/udev/rules.d/80-unit-link-keep.rules";
    text = ''
      SUBSYSTEM=="net", ACTION=="add", NAME=="", NAME="$env{INTERFACE}"
    '';
  };

  # eudev keeps the rules and hwdb files it ships under var/lib; present them
  # where the rule collector below looks.
  udevDefaults = pkgs.runCommand "eudev-default-rules" { } ''
    mkdir -p $out/lib/udev
    ln -s ${udev}/var/lib/udev/rules.d $out/lib/udev/rules.d
    ln -s ${udev}/var/lib/udev/hwdb.d $out/lib/udev/hwdb.d
  '';

  extraUdevRules = pkgs.writeTextFile {
    name = "extra-udev-rules";
    text = cfg.extraRules;
    destination = "/etc/udev/rules.d/99-local.rules";
  };

  extraHwdbFile = pkgs.writeTextFile {
    name = "extra-hwdb-file";
    text = cfg.extraHwdb;
    destination = "/etc/udev/hwdb.d/99-local.hwdb";
  };

  nixosInitrdRules = ''
    # Mark dm devices as db_persist so that they are kept active after switching root
    SUBSYSTEM=="block", KERNEL=="dm-[0-9]*", ACTION=="add|change", OPTIONS+="db_persist"
  '';

  # Collect the rules of all packages into one directory and fix up paths.
  udevRules =
    pkgs.runCommand "udev-rules"
      {
        preferLocalBuild = true;
        allowSubstitutes = false;
        packages = lib.unique (map toString ([ udevDefaults ] ++ cfg.packages));
      }
      ''
        mkdir -p $out
        shopt -s nullglob
        set +o pipefail

        # Set a reasonable $PATH for programs called by udev rules.
        echo 'ENV{PATH}="${udevPath}/bin:${udevPath}/sbin"' > $out/00-path.rules

        # Add the udev rules from other packages.
        for i in $packages; do
          echo "Adding rules for package $i"
          for j in $i/{etc,lib}/udev/rules.d/*; do
            echo "Copying $j to $out/$(basename $j)"
            cat $j > $out/$(basename $j)
          done
        done

        # Fix some paths in the standard udev rules.  Hacky.
        for i in $out/*.rules; do
          substituteInPlace $i \
            --replace-quiet \"/sbin/modprobe \"${pkgs.kmod}/bin/modprobe \
            --replace-quiet \"/sbin/mdadm \"${pkgs.mdadm}/sbin/mdadm \
            --replace-quiet \"/sbin/blkid \"${pkgs.util-linux}/sbin/blkid \
            --replace-quiet \"/bin/mount \"${pkgs.util-linux}/bin/mount \
            --replace-quiet /usr/bin/readlink ${pkgs.coreutils}/bin/readlink \
            --replace-quiet /usr/bin/cat ${pkgs.coreutils}/bin/cat \
            --replace-quiet /usr/bin/basename ${pkgs.coreutils}/bin/basename 2>/dev/null
        done

        echo -n "Checking that all programs called by relative paths in udev rules exist in ${udev}/lib/udev... "
        import_progs=$(grep 'IMPORT{program}="[^/$]' $out/* |
          sed -e 's/.*IMPORT{program}="\([^ "]*\)[ "].*/\1/' | uniq)
        run_progs=$(grep -v '^[[:space:]]*#' $out/* | grep 'RUN+="[^/$]' |
          sed -e 's/.*RUN+="\([^ "]*\)[ "].*/\1/' | uniq)
        for i in $import_progs $run_progs; do
          if [[ ! -x ${udev}/lib/udev/$i && ! $i =~ socket:.* ]]; then
            echo "FAIL"
            echo "$i is called in udev rules but not installed by udev"
            exit 1
          fi
        done
        echo "OK"

        echo -n "Checking that all programs called by absolute paths in udev rules exist... "
        import_progs=$(grep 'IMPORT{program}="/' $out/* |
          sed -e 's/.*IMPORT{program}="\([^ "]*\)[ "].*/\1/' | uniq)
        run_progs=$(grep -v '^[[:space:]]*#' $out/* | grep 'RUN+="/' |
          sed -e 's/.*RUN+="\([^ "]*\)[ "].*/\1/' | uniq)
        for i in $import_progs $run_progs; do
          # /run/current-system/systemd is the shim package on a running system
          if [[ $i == /run/current-system/systemd* ]]; then
            i="${config.systemd.package}/''${i#/run/current-system/systemd/}"
          fi

          if [[ ! -x $i ]]; then
            echo "FAIL"
            echo "$i is called in udev rules but is not executable or does not exist"
            exit 1
          fi
        done
        echo "OK"

        filesToFixup="$(for i in "$out"/*; do
          # list all files referring to (/usr)/bin paths, but allow references to /bin/sh.
          grep -P -l '\B(?!\/bin\/sh\b)(\/usr)?\/bin(?:\/.*)?' "$i" || :
        done)"

        if [ -n "$filesToFixup" ]; then
          echo "Consider fixing the following udev rules:"
          echo "$filesToFixup" | while read localFile; do
            remoteFile="origin unknown"
            for i in ${toString cfg.packages}; do
              for j in "$i"/*/udev/rules.d/*; do
                [ -e "$out/$(basename "$j")" ] || continue
                [ "$(basename "$j")" = "$(basename "$localFile")" ] || continue
                remoteFile="originally from $j"
                break 2
              done
            done
            refs="$(
              grep -o '\B\(/usr\)\?/s\?bin/[^ "]\+' "$localFile" \
                | sed -e ':r;N;''${s/\n/ and /;br};s/\n/, /g;br'
            )"
            echo "$localFile ($remoteFile) contains references to $refs."
          done
          exit 1
        fi

        # If auto-configuration is disabled, then remove
        # udev's 80-drivers.rules file, which contains rules for
        # automatically calling modprobe.
        ${lib.optionalString (!config.boot.hardwareScan) ''
          ln -s /dev/null $out/80-drivers.rules
        ''}
      '';

  hwdbBin =
    pkgs.runCommand "hwdb.bin"
      {
        preferLocalBuild = true;
        allowSubstitutes = false;
        packages = lib.unique (map toString ([ udevDefaults ] ++ cfg.packages));
        nativeBuildInputs = [ pkgs.buildPackages.eudev ];
      }
      ''
        mkdir -p etc/udev/hwdb.d
        for i in $packages; do
          echo "Adding hwdb files for package $i"
          for j in $i/{etc,lib}/udev/hwdb.d/*; do
            # This must be a copy, not a symlink, because --root below will chase links within the root argument.
            cp $j etc/udev/hwdb.d/$(basename $j)
          done
        done

        echo "Generating hwdb database..."
        res="$(udevadm hwdb --update --root=$(pwd) 2>&1)"
        echo "$res"
        [ -z "$(echo "$res" | grep -E '^Error')" ]
        mv etc/udev/hwdb.bin $out
      '';

  # Udev has a 512-character limit for ENV{PATH}, so create a symlink
  # tree to work around this.
  udevPath = pkgs.buildEnv {
    name = "udev-path";
    paths = cfg.path;
    pathsToLink = [
      "/bin"
      "/sbin"
    ];
    ignoreCollisions = true;
  };
in

{
  options.services.udev.package = lib.mkPackageOption pkgs "eudev" { };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion =
          config.hardware.firmwareCompression == "zstd" -> config.boot.kernelPackages.kernelAtLeast "5.19";
        message = ''
          The firmware compression method is set to zstd, but the kernel version is too old.
          The kernel version must be at least 5.19 to use zstd compression.
        '';
      }
      {
        assertion =
          config.hardware.firmwareCompression == "xz" -> config.boot.kernelPackages.kernelAtLeast "5.3";
        message = ''
          The firmware compression method is set to xz, but the kernel version is too old.
          The kernel version must be at least 5.3 to use xz compression.
        '';
      }
    ];

    services.udev.packages = [
      extraUdevRules
      extraHwdbFile
      linkRules
      linkKeepRules
    ];

    # as upstream's networkd.nix has it (its configuration is not imported
    # here, networkd not being supported): .link files are udev's
    systemd.network.units = lib.mapAttrs' (
      n: v:
      lib.nameValuePair "${n}.link" {
        inherit (v) enable;
        text = utils.systemdUtils.network.units.linkToUnit v;
      }
    ) config.systemd.network.links;

    services.udev.path = [
      pkgs.coreutils
      pkgs.gnused
      pkgs.gnugrep
      pkgs.util-linux
      udev
    ];

    environment.systemPackages = [ udev ];

    boot.kernelParams = lib.mkIf (!config.networking.usePredictableInterfaceNames) [ "net.ifnames=0" ];

    boot.initrd.extraUdevRulesCommands = lib.mkIf (config.boot.initrd.services.udev.rules != "") ''
      cat <<'EOF' > $out/99-local.rules
      ${config.boot.initrd.services.udev.rules}
      EOF
    '';

    boot.initrd.services.udev.rules = nixosInitrdRules;

    environment.etc = {
      "udev/rules.d".source = udevRules;
      "udev/hwdb.bin".source = hwdbBin;
    }
    // lib.mapAttrs' (
      name: unit: lib.nameValuePair "systemd/network/${name}" { source = "${unit.unit}/${name}"; }
    ) config.systemd.network.units
    // lib.optionalAttrs config.boot.modprobeConfig.enable {
      # We don't place this into `extraModprobeConfig` so that stage-1 ramdisk doesn't bloat.
      "modprobe.d/firmware.conf".text =
        "options firmware_class path=${config.hardware.firmware}/lib/firmware";
    };

    system.requiredKernelConfig = with config.lib.kernelConfig; [
      (isEnabled "UNIX")
      (isYes "INOTIFY_USER")
      (isYes "NET")
    ];

    system.activationScripts.udevd = lib.mkIf config.boot.kernel.enable ''
      # The deprecated hotplug uevent helper is not used anymore
      if [ -e /proc/sys/kernel/hotplug ]; then
        echo "" > /proc/sys/kernel/hotplug
      fi

      # Allow the kernel to find our firmware.
      if [ -e /sys/module/firmware_class/parameters/path ]; then
        echo -n "${config.hardware.firmware}/lib/firmware" > /sys/module/firmware_class/parameters/path
      fi
    '';

    systemd.services.systemd-udevd = {
      description = "Device Manager (eudev)";
      wantedBy = [ "sysinit.target" ];
      before = [ "sysinit.target" ];
      after = [ "systemd-tmpfiles-setup-dev.service" ];
      unitConfig = {
        DefaultDependencies = false;
        X-S6-Name = "udevd";
        ConditionPathIsReadWrite = "/sys";
      };
      restartTriggers = [ udevRules ];
      stopIfChanged = false;
      serviceConfig = {
        ExecStart = "${udev}/bin/udevd";
        # eudev has no readiness protocol; its control socket appears once it
        # is listening for events.
        ExecStartPost = pkgs.writeShellScript "udevd-wait-ready" ''
          for _ in $(${pkgs.coreutils}/bin/seq 100); do
            [ -S /run/udev/control ] && exit 0
            ${pkgs.coreutils}/bin/sleep 0.05
          done
          echo "udevd did not create /run/udev/control" >&2
          exit 1
        '';
        ExecReload = "${udev}/bin/udevadm control --reload";
        Restart = "always";
        RestartSec = 0;
        KillMode = "mixed";
        OOMScoreAdjust = -1000;
      };
    };

    systemd.services.systemd-udev-trigger = {
      description = "Coldplug All udev Devices";
      wantedBy = [ "sysinit.target" ];
      requires = [ "systemd-udevd.service" ];
      after = [ "systemd-udevd.service" ];
      before = [ "sysinit.target" ];
      unitConfig = {
        DefaultDependencies = false;
        X-S6-Name = "udev-trigger";
        ConditionPathIsReadWrite = "/sys";
      };
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = [
          "${udev}/bin/udevadm trigger --type=subsystems --action=add"
          "${udev}/bin/udevadm trigger --type=devices --action=add"
        ];
      };
    };

    # Starts the units that are wanted by a device (`wantedBy = [ "….device" ]`,
    # or SYSTEMD_WANTS in a udev rule) when that device appears.
    s6.rc.services.device-watch = {
      type = "longrun";
      wantedByDefault = true;
      dependencies = [ "udevd" ];
      run = ''
        #!${pkgs.runtimeShell}
        exec 2>&1
        live=$(${pkgs.coreutils}/bin/readlink -f /run/s6-rc/compiled)
        exec ${config.system.build.unitRuntime}/bin/unit-runtime device-watch "''${live%/*}"
      '';
    };

    # With systemd, units wait for the device units they need.  s6-rc has no
    # such thing, so let the initial burst of events settle before anything
    # past sysinit.target starts.
    systemd.services.systemd-udev-settle = {
      description = "Wait for udev To Complete Device Initialization";
      wantedBy = [ "sysinit.target" ];
      wants = [ "systemd-udevd.service" ];
      after = [ "systemd-udev-trigger.service" ];
      before = [ "sysinit.target" ];
      unitConfig = {
        DefaultDependencies = false;
        X-S6-Name = "udev-settle";
        ConditionPathIsReadWrite = "/sys";
      };
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        TimeoutSec = 180;
        ExecStart = "${udev}/bin/udevadm settle --timeout=120";
      };
    };
  };
}
