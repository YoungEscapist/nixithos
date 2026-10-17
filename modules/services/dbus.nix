# The system bus.
#
# nixos/modules/services/system/dbus.nix stays in charge of configuration and
# users.  What changes is how the daemon is run:
#
#   * dbus-broker (the upstream default) hands every activation request to
#     systemd, so the reference dbus-daemon is used;
#   * dbus-daemon opens its socket itself instead of receiving it from the
#     service manager, which only works when it is built with systemd
#     support, and reports readiness by printing its address;
#   * it runs without --systemd-activation: bus-activated services are
#     launched from the `Exec=` line of their D-Bus service file, through the
#     setuid helper, as on any system without systemd;
#   * except those that systemd would start as a unit (`SystemdService=`):
#     their `Exec=` is often a stub (`/bin/false`), or a bare command line
#     without the unit's configuration (`wpa_supplicant -u`).  Copies of their
#     service files, looked at first, start the unit instead.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.dbus;

  # Exec= of such a service: start the unit, and stay until the name is on
  # the bus (dbus-daemon takes an activation that ends before for a failure).
  # The session bus of a user does the same with the user's units.
  activate = pkgs.writeShellScript "dbus-unit-activate" ''
    export PATH=${
      lib.makeBinPath [
        pkgs.coreutils
        pkgs.gnugrep
        cfg.dbusPackage
        config.systemd.package
      ]
    }
    scope=$1 unit=$2 name=$3
    if [ "$scope" = user ]; then ctl="systemctl --user" bus=--session; else ctl=systemctl bus=--system; fi
    $ctl start "$unit" || exit 1
    for i in $(seq 900); do
      if dbus-send $bus --print-reply --dest=org.freedesktop.DBus /org/freedesktop/DBus \
          org.freedesktop.DBus.NameHasOwner "string:$name" 2>/dev/null | grep -q 'boolean true'; then
        exit 0
      fi
      case $($ctl is-active "$unit") in failed | inactive) exit 1 ;; esac
      sleep 0.1
    done
    exit 1
  '';

  unitActivation =
    pkgs.runCommand "dbus-unit-activation"
      {
        packages = cfg.packages;
        preferLocalBuild = true;
      }
      ''
        copy() {
          scope=$1 from=$2 d=$out/share/dbus-1/$2
          mkdir -p $d
          for p in $packages; do
            for f in $p/share/dbus-1/$from/*.service; do
              [ -f "$f" ] || continue
              unit=$(sed -n 's/^SystemdService=//p' "$f" | head -n 1)
              name=$(sed -n 's/^Name=//p' "$f" | head -n 1)
              [ -n "$unit" ] && [ -n "$name" ] || continue
              # (the first package has it, as for dbus-daemon)
              [ -e "$d/''${f##*/}" ] && continue
              {
                printf '%s\n' '[D-BUS Service]' "Name=$name" "Exec=${activate} $scope $unit $name"
                [ "$scope" = system ] && printf '%s\n' 'User=root'
                printf '%s\n' "SystemdService=$unit"
              } > "$d/''${f##*/}"
            done
          done
        }
        copy system system-services
        copy user services
      '';
in

{
  config = lib.mkIf cfg.enable {
    services.dbus.implementation = lib.mkForce "dbus";

    environment.etc."dbus-1".source = lib.mkForce (
      pkgs.makeDBusConf.override {
        inherit (cfg) apparmor;
        dbus = cfg.dbusPackage;
        suidHelper = "${config.security.wrapperDir}/dbus-daemon-launch-helper";
        serviceDirectories = [ unitActivation ] ++ cfg.packages;
      }
    );

    systemd.services.dbus = {
      description = "D-Bus System Message Bus";
      wantedBy = [ "multi-user.target" ];
      before = [ "basic.target" ];
      # Units name dbus.socket to say "once the bus can be reached".
      aliases = [ "dbus.socket" ];
      unitConfig = {
        # Not the unit the dbus package may ship: it relies on socket passing.
        X-Replace = true;
        DefaultDependencies = false;
        Requires = "sysinit.target";
        After = "sysinit.target";
      };
      serviceConfig = {
        ExecStart = "${cfg.dbusPackage}/bin/dbus-daemon --system --nofork --nopidfile --syslog-only --print-address=3";
        X-NotifyFd = 3;
        ExecReload = "${cfg.dbusPackage}/bin/dbus-send --print-reply --system --type=method_call --dest=org.freedesktop.DBus / org.freedesktop.DBus.ReloadConfig";
        RuntimeDirectory = "dbus";
        RuntimeDirectoryPreserve = true;
        OOMScoreAdjust = -900;
      };
    };

    # The session bus of each user, at $XDG_RUNTIME_DIR/bus, where libdbus
    # looks when DBUS_SESSION_BUS_ADDRESS is not set.
    systemd.user.services.dbus = {
      description = "D-Bus User Message Bus";
      wantedBy = [ "default.target" ];
      aliases = [ "dbus.socket" ];
      unitConfig.X-Replace = true;
      serviceConfig = {
        ExecStart = "${cfg.dbusPackage}/bin/dbus-daemon --session --nofork --nopidfile --syslog-only --address=unix:path=%t/bus --print-address=3";
        X-NotifyFd = 3;
        ExecReload = "${cfg.dbusPackage}/bin/dbus-send --print-reply --session --type=method_call --dest=org.freedesktop.DBus / org.freedesktop.DBus.ReloadConfig";
      };
    };
  };
}
