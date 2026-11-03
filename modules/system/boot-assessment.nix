# Boot assessment: a generation that was just installed to boot from is "on
# trial" until a boot into it has got to the end.  If it does not (the machine
# panics, resets, hangs, or the units the boot has to bring up do not come
# up), the boot loader goes back to the generation that was running, by
# itself, after `tries` attempts.  The tool is pkgs/boot-assess.
#
#   systemd-boot   its boot counting (the entry file gets +N in its name)
#   GRUB           grubenv, and a piece of grub.cfg that counts down
#   Limine         the old generation is the default; the new one is started
#                  once through a UEFI boot entry (BootNext)
#   rEFInd         not supported (nothing in it counts, and it cannot start a
#                  generation once); same as Limine would do, untested
#
# The end of the boot is where the init system says so: after rc.init has got
# to the steady service database (s6), or when the `boot` service has run
# (dinit).  Both call the program that /etc/units/boot-hook names.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.nixithos.bootAssessment;
  bl = config.boot.loader;

  loader =
    if bl.systemd-boot.enable then
      "systemd-boot"
    else if bl.limine.enable then
      "limine"
    else if bl.refind.enable then
      "refind"
    else if bl.grub.enable then
      "grub"
    else
      "none";

  bootDir =
    {
      systemd-boot =
        if bl.systemd-boot.xbootldrMountPoint != null then
          bl.systemd-boot.xbootldrMountPoint
        else
          bl.efi.efiSysMountPoint;
      limine = bl.efi.efiSysMountPoint;
      grub = (lib.head bl.grub.mirroredBoots).path;
    }
    .${loader} or "/boot";

  assess = pkgs.nixithos.bootAssess.override {
    inherit loader bootDir;
    espDir = bl.efi.efiSysMountPoint;
    inherit (cfg) tries;
    required = cfg.requiredUnits;
    efiSupport = loader == "limine" && bl.limine.efiSupport;
    grubPackage = if loader == "grub" then bl.grub.package else null;
    efibootmgr = if loader == "limine" then pkgs.efibootmgr else null;
  };

  # what the boot loader installer is followed by
  assessed = pkgs.writeShellScript "install-boot-loader-assessed" ''
    ${config.system.build.installBootLoader} "$@" || exit $?
    ${assess}/bin/nixith-boot-assess arm "$1" ||
      echo "warning: the boot assessment could not be set up" >&2
    exit 0
  '';

  # What GRUB does with it, in grub.cfg (after `set default=`, before the
  # entries).  nixith_trial is the entry of the generation on trial,
  # nixith_good the one to go back to, nixith_tries what is left; the entries'
  # ids are put there by the tool.  A try is counted down and saved before
  # it is used; if grubenv cannot be written (what is read back is not what
  # was saved) the trial is given up, rather than repeated for ever.
  grubConfig = ''
    # NixithOS boot assessment (nixith-boot-assess)
    if [ -n "''${nixith_trial}" ]; then
      if [ -z "''${boot_once}" ]; then
        set nixith_left=
        ${lib.concatMapStrings (k: ''
          if [ "''${nixith_tries}" = ${toString k} ]; then set nixith_left=${toString (k - 1)}; fi
        '') (lib.range 1 cfg.tries)}
        if [ -z "''${nixith_left}" ]; then
          set default="''${nixith_good}"
        else
          set nixith_tries="''${nixith_left}"
          save_env nixith_tries
          load_env nixith_tries
          if [ "''${nixith_tries}" = "''${nixith_left}" ]; then
            set default="''${nixith_trial}"
          else
            set default="''${nixith_good}"
          fi
        fi
      fi
    fi
  '';
in

{
  options.nixithos.bootAssessment = {
    enable = lib.mkEnableOption "boot assessment: a new generation is on trial until a boot into it has got to the end, and the boot loader goes back to the one that was running if it does not";

    tries = lib.mkOption {
      type = lib.types.ints.between 1 9;
      default = 3;
      description = ''
        How many times the boot loader tries a generation that is on trial.
        systemd-boot and GRUB count; Limine can only start the new
        generation once, whatever this is.
      '';
    };

    requiredUnits = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [
        "sshd.service"
        "NetworkManager.service"
      ];
      description = ''
        System units that must be active at the end of the boot for it to
        count as a good one.  By default a boot is good when it has got to
        the end, whatever failed on the way (a broken unit is not worth going
        back for, usually); list the ones you could not do without (the
        network on a machine you reach over it).
      '';
    };

    installer = lib.mkOption {
      type = lib.types.unspecified;
      internal = true;
      readOnly = true;
      description = "What switch-to-configuration runs to install the boot loader.";
    };
  };

  config = lib.mkMerge [
    {
      nixithos.bootAssessment.installer =
        if cfg.enable then assessed else config.system.build.installBootLoader;
    }

    (lib.mkIf cfg.enable {
      assertions = [
        {
          assertion = loader != "none" && loader != "refind";
          message = ''
            nixithos.bootAssessment.enable: the boot loader (${loader}) is not one that boot assessment works with: systemd-boot, GRUB and Limine (on EFI) are.
          '';
        }
        {
          assertion = loader != "limine" || !bl.limine.enrollConfig;
          message = "nixithos.bootAssessment.enable: Limine's config is enrolled in its binary (boot.loader.limine.enrollConfig); the assessment has to change it.";
        }
      ];

      environment.systemPackages = [ assess ];
      system.build.bootAssess = assess;

      # the end of the boot (rc.init under s6, the `boot` service under dinit)
      environment.etc."units/boot-hook".text = "${assess}/bin/nixith-boot-assess\n";

      boot.loader.grub.extraConfig = lib.mkIf (loader == "grub") grubConfig;
    })
  ];
}
