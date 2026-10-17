# Login prompts.
#
# nixos/modules/services/ttys/getty.nix stays in the module list as it is: it
# only sets `ExecStart` for the getty units that ship with systemd.  This
# module supplies those units, and decides where a getty runs.  systemd makes
# that decision at run time (logind starts one per virtual console on demand,
# a generator adds serial consoles); the s6-rc database is compiled ahead of
# time, so here it is configuration.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.getty;

  common = {
    after = [ "systemd-user-sessions.service" ];
    before = [ "getty.target" ];
    serviceConfig = {
      Type = "idle";
      Restart = "always";
      RestartSec = 0;
      KillMode = "process";
      SendSIGHUP = true;
      # agetty opens its terminal itself; what it says before that goes to the log.
      StandardInput = "null";
    };
    unitConfig.StartLimitIntervalSec = 0;
    restartIfChanged = false;
  };

  agettyArgs = [
    "--login-program"
    "${cfg.loginProgram}"
    "--issue-file"
    "/etc/issue:/etc/issue.d:/run/issue:/run/issue.d"
  ]
  ++ lib.optionals (cfg.autologinUser != null && !cfg.autologinOnce) [
    "--autologin"
    cfg.autologinUser
  ]
  ++ lib.optionals (cfg.loginOptions != null) [
    "--login-options"
    cfg.loginOptions
  ]
  ++ cfg.extraArgs;

  # The kernel's preferred console, if it is a serial line without a getty of
  # its own.  /sys lists the consoles in order, the preferred one last.
  kernelConsole = pkgs.writeShellScript "kernel-console" ''
    tty=
    for c in $(< /sys/class/tty/console/active); do tty=$c; done
    case $tty in
      "" | tty[0-9]*) exit 1 ;;
      ${lib.concatMapStringsSep " | " lib.escapeShellArg (cfg.serialConsoles ++ [ "none" ])}) exit 1 ;;
    esac
    [ -c "/dev/$tty" ] || exit 1
    if [ "''${1-}" = getty ]; then
      exec ${pkgs.util-linux}/bin/agetty ${lib.escapeShellArgs agettyArgs} --keep-baud "$tty" 115200,57600,38400,9600 "$TERM"
    fi
  '';

  # console=… arguments that name something other than the virtual consoles
  kernelSerialConsoles = lib.unique (
    lib.concatMap (
      param:
      let
        m = builtins.match "console=((ttyS|ttyAMA|ttyUSB|ttyACM|hvc|ttyO|ttymxc|ttyPS|ttySAC)[0-9]+)(,.*)?" param;
      in
      lib.optional (m != null) (lib.head m)
    ) config.boot.kernelParams
  );
in

{
  options.services.getty = {
    virtualConsoles = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = map (n: "tty${toString n}") (lib.range 1 6);
      defaultText = lib.literalExpression ''[ "tty1" "tty2" "tty3" "tty4" "tty5" "tty6" ]'';
      description = ''
        Virtual consoles to run a login prompt on.  A terminal used by a
        display manager is skipped automatically if it does not exist yet;
        remove it from this list if both would compete for it.
      '';
    };

    serialConsoles = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = kernelSerialConsoles;
      defaultText = lib.literalMD "the serial consoles named by `console=` in {option}`boot.kernelParams`";
      example = [ "ttyS0" ];
      description = "Serial lines to run a login prompt on.";
    };

    kernelConsole = lib.mkOption {
      type = lib.types.bool;
      default = !config.boot.isContainer;
      defaultText = lib.literalExpression "!config.boot.isContainer";
      description = ''
        Whether to also run a login prompt on whatever serial line the kernel
        was told to use as its console when it booted (`console=` given by the
        boot loader or the hypervisor), if {option}`services.getty.serialConsoles`
        does not cover it already.
      '';
    };
  };

  config = lib.mkMerge [ {
    systemd.services."getty@" = lib.recursiveUpdate common {
      description = "Getty on %I";
      unitConfig.ConditionPathExists = "/dev/%I";
      environment.TERM = "linux";
      # (as in systemd's unit: the terminal is the unit's, which keeps the
      # boot's progress off it when it is the console - see console_mark)
      serviceConfig.TTYPath = "/dev/%I";
    };

    systemd.services."serial-getty@" = lib.recursiveUpdate common {
      description = "Serial Getty on %I";
      unitConfig.ConditionPathExists = "/dev/%I";
      environment.TERM = "vt220";
    };

    systemd.services."container-getty@" = lib.recursiveUpdate common {
      description = "Container Getty on /dev/pts/%I";
      environment.TERM = "vt220";
    };

    systemd.services.console-getty = lib.recursiveUpdate common {
      description = "Console Getty";
      environment.TERM = "vt220";
      wantedBy = [ "getty.target" ];
    };

    systemd.services.serial-getty-console = lib.mkIf cfg.kernelConsole (
      lib.recursiveUpdate common {
        description = "Getty on the Kernel Console";
        environment.TERM = "vt220";
        wantedBy = [ "getty.target" ];
        serviceConfig = {
          ExecCondition = "${kernelConsole}";
          ExecStart = "${kernelConsole} getty";
        };
      }
    );

    systemd.targets.getty.wants =
      map (tty: "getty@${tty}.service") (
        lib.optionals (!config.boot.isContainer) (
          # upstream's module already asks for tty1 unless a display manager wants it
          lib.filter (tty: tty != "tty1") cfg.virtualConsoles
        )
      )
      ++ map (tty: "serial-getty@${tty}.service") cfg.serialConsoles;
  }

  # tty2 and up: as with logind's autovt, the login prompt comes when the
  # console is switched to, not at boot (see unit-vt-wait).  The service is
  # up all along, waiting.  With automatic login, this is what keeps the user
  # from being logged in on six consoles at once - and from logind choosing
  # one that is not on the screen as their session, which polkit then turns
  # down (rtkit).
  {
    systemd.services = lib.listToAttrs (
      map (
        tty:
        lib.nameValuePair "getty@${tty}" {
          overrideStrategy = "asDropin";
          serviceConfig.X-WaitForVT = true;
        }
      ) (lib.filter (tty: tty != "tty1") cfg.virtualConsoles)
    );
  } ];
}
