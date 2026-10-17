# What `config.systemd.package` points at on a system without systemd.
#
# Upstream NixOS modules reach into the systemd package for paths
# (`${config.systemd.package}/bin/systemctl`, `…/example/tmpfiles.d/tmp.conf`)
# and for feature flags (`config.systemd.package.withLogind`).  This package
# keeps those references meaningful: it has the same layout, but the files in
# it are small front-ends for the s6 tooling, and every feature flag that
# stands for a systemd daemon reports `false`.
{
  lib,
  runCommand,
  replaceVarsWith,
  runtimeShell,
  bash,
  coreutils,
  gnugrep,
  gnused,
  gawk,
  getent,
  util-linux,
  kbd,
  kmod,
  eudev,
  s6,
  s6-rc,
  s6-linux-init,
  nixithos,

  # elogind, if there is a login manager: PAM then gets its session module
  # under the name it is looked up by, and `loginctl` exists.
  elogind ? null,

  # systemd-boot's tools (./boot-tool.nix), if that boot loader is in use:
  # `bootctl` and the EFI programs, at the places NixOS looks for them.
  bootTool ? null,

  # `busctl` and `systemd-analyze security` (./client-tools.nix): the first is
  # linked into bin/, `systemd-analyze` hands that subcommand to the second.
  clientTools ? null,
}:

let
  script =
    name:
    replaceVarsWith {
      inherit name;
      src = ./. + "/${name}.sh";
      isExecutable = true;
      replacements = {
        shell = "${bash}/bin/bash";
        path = lib.makeBinPath [
          coreutils
          gnugrep
          gnused
          gawk
          getent
          util-linux
          s6
          s6-rc
          s6-linux-init
          nixithos.unitTools
        ];
        runtime = "${nixithos.unitRuntime}/bin/unit-runtime";
      }
      // lib.optionalAttrs (name == "systemd-analyze") {
        analyze = if clientTools != null then "${clientTools}/bin/systemd-analyze" else "";
      };
      postInstall = ''
        ${bash}/bin/bash -n $target
      '';
    };

  scripts = [
    "systemctl"
    "journalctl"
    "systemd-run"
    "systemd-notify"
    "systemd-detect-virt"
    "systemd-escape"
    "systemd-cat"
    "systemd-machine-id-setup"
    "systemd-inhibit"
    "systemd-creds"
    "systemd-analyze"
    "systemd-ask-password"
    "hostnamectl"
    "timedatectl"
  ]
  # (elogind has its own)
  ++ lib.optional (elogind == null) "loginctl";
in

runCommand "systemd-shim"
  {
    passthru = {
      # Compared by switch-to-configuration to decide whether init itself has
      # to be re-executed; unrelated to systemd's own number.
      interfaceVersion = 2;

      inherit util-linux kbd kmod;

      withAnalyze = false;
      withApparmor = false;
      withBootloader = false;
      withCoredump = false;
      withCryptsetup = false;
      withEfi = false;
      withFido2 = false;
      withHomed = false;
      withHostnamed = false;
      withImportd = false;
      withKmod = true;
      withLocaled = false;
      withLogind = elogind != null;
      withMachined = false;
      withNetworkd = false;
      withNspawn = false;
      withNss = false;
      withOomd = false;
      withPortabled = false;
      withRepart = false;
      withResolved = false;
      withSysupdate = false;
      withSysusers = false;
      withTimedated = false;
      withTimesyncd = false;
      withTpm2Tss = false;
      withTpm2Units = false;
      withUkify = false;
      withUserDb = false;
      withUtmp = false;
    };

    meta = {
      description = "Stand-in for the systemd package on an s6-rc based NixOS";
      platforms = lib.platforms.linux;
    };
  }
  ''
    mkdir -p $out/bin $out/lib/systemd $out/lib/udev $out/example/sysctl.d

    ${lib.concatMapStringsSep "\n" (name: "ln -s ${script name} $out/bin/${name}") scripts}

    # tmpfiles.d and sysusers.d are implemented by sd-tools
    ln -s ${nixithos.sd-tools}/bin/sd-tmpfiles $out/bin/systemd-tmpfiles
    ln -s ${nixithos.sd-tools}/bin/sd-sysusers $out/bin/systemd-sysusers

    # udev is eudev
    ln -s ${eudev}/bin/udevadm $out/bin/udevadm
    ln -s ${eudev}/bin/udevd $out/lib/systemd/systemd-udevd
    for helper in ${eudev}/lib/udev/*; do
      [ -f "$helper" ] && ln -s "$helper" $out/lib/udev/
    done

    # libudev: nixpkgs packages get it from `systemdMinimal`/`systemdLibs`
    # (umockdev, libgudev, …), so what stands in for those has to have it.
    mkdir -p $out/lib/pkgconfig $out/include
    for lib in ${eudev}/lib/libudev.so*; do
      ln -s "$lib" $out/lib/
    done
    ln -s ${eudev}/include/libudev.h $out/include/libudev.h
    ln -s ${eudev}/lib/pkgconfig/libudev.pc $out/lib/pkgconfig/libudev.pc

    ${lib.optionalString (clientTools != null) ''
      ln -s ${clientTools}/bin/busctl $out/bin/busctl
    ''}

    ${lib.optionalString (bootTool != null) ''
      ln -s ${bootTool}/bin/bootctl $out/bin/bootctl
      ln -s ${bootTool}/lib/systemd/boot $out/lib/systemd/boot
    ''}

    ${lib.optionalString (elogind != null) ''
      mkdir -p $out/lib/security
      ln -s ${elogind}/lib/security/pam_elogind.so $out/lib/security/pam_systemd.so
      ln -s ${elogind}/bin/loginctl $out/bin/loginctl
    ''}

    # init
    for cmd in halt poweroff reboot; do
      ln -s systemctl $out/bin/$cmd
    done
    ln -s ${s6-linux-init}/bin/s6-linux-init-shutdown $out/bin/shutdown

    mkdir -p $out/example/tmpfiles.d
    touch $out/example/sysctl.d/50-default.conf

    # Many packages ask pkg-config about "systemd" for one reason only: to
    # learn where unit files, tmpfiles.d snippets and the like are installed.
    # Answer that, so that they build and keep shipping those files (which is
    # what the unit compiler reads).  Everything is relative to ''${prefix},
    # because that is what such packages redefine to point into their own
    # output (`pkg-config --define-variable prefix=… --variable …`).  There is
    # deliberately no libsystemd.pc.
    mkdir -p $out/share/pkgconfig
    cat > $out/share/pkgconfig/systemd.pc <<'EOF'
    root_prefix=@out@
    rootprefix=''${root_prefix}
    prefix=''${rootprefix}
    sysconf_dir=/etc
    sysconfdir=''${sysconf_dir}

    systemd_util_dir=''${prefix}/lib/systemd
    systemdutildir=''${systemd_util_dir}
    systemd_system_unit_dir=''${prefix}/lib/systemd/system
    systemdsystemunitdir=''${systemd_system_unit_dir}
    systemd_system_preset_dir=''${prefix}/lib/systemd/system-preset
    systemdsystempresetdir=''${systemd_system_preset_dir}
    systemd_user_unit_dir=''${prefix}/lib/systemd/user
    systemduserunitdir=''${systemd_user_unit_dir}
    systemd_user_preset_dir=''${prefix}/lib/systemd/user-preset
    systemduserpresetdir=''${systemd_user_preset_dir}
    systemd_system_conf_dir=''${sysconfdir}/systemd/system
    systemdsystemconfdir=''${systemd_system_conf_dir}
    systemd_user_conf_dir=''${sysconfdir}/systemd/user
    systemduserconfdir=''${systemd_user_conf_dir}
    systemd_system_generator_dir=''${prefix}/lib/systemd/system-generators
    systemdsystemgeneratordir=''${systemd_system_generator_dir}
    systemd_user_generator_dir=''${prefix}/lib/systemd/user-generators
    systemdusergeneratordir=''${systemd_user_generator_dir}
    systemd_sleep_dir=''${prefix}/lib/systemd/system-sleep
    systemdsleepdir=''${systemd_sleep_dir}
    systemd_shutdown_dir=''${prefix}/lib/systemd/system-shutdown
    systemdshutdowndir=''${systemd_shutdown_dir}
    tmpfiles_dir=''${prefix}/lib/tmpfiles.d
    tmpfilesdir=''${tmpfiles_dir}
    sysusers_dir=''${prefix}/lib/sysusers.d
    sysusersdir=''${sysusers_dir}
    sysctl_dir=''${prefix}/lib/sysctl.d
    sysctldir=''${sysctl_dir}
    binfmt_dir=''${prefix}/lib/binfmt.d
    binfmtdir=''${binfmt_dir}
    modules_load_dir=''${prefix}/lib/modules-load.d
    modulesloaddir=''${modules_load_dir}
    catalog_dir=''${prefix}/lib/systemd/catalog
    catalogdir=''${catalog_dir}
    system_uid_max=999
    systemuidmax=''${system_uid_max}
    system_gid_max=999
    systemgidmax=''${system_gid_max}

    Name: systemd
    Description: Directory layout for unit files (no systemd behind it)
    Version: 260
    EOF
    sed -i -e 's/^    //' -e "s|@out@|$out|" $out/share/pkgconfig/systemd.pc
  ''
