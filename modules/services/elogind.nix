# elogind: login sessions, seats, power keys and inhibitors - systemd-logind
# without systemd.
#
# The settings are upstream's `services.logind.settings.Login`, so
# configurations written for NixOS keep working.  elogind reads the main file
# from its own store path and drop-ins from /etc/elogind/logind.conf.d, which
# is where the NixOS settings go.
{
  config,
  lib,
  pkgs,
  utils,
  ...
}:

let
  cfg = config.services.elogind;
  logindSettings = config.services.logind.settings;

  # A session whose leader has exited is finalised by the garbage collector,
  # which refuses to as long as it finds the leader "alive".  A process that
  # has exited but not yet been reaped by its parent counts as alive, and the
  # supervisor of a getty (which is what the leader's parent is) reaps a
  # moment after logind has been told of the exit.  Logind then looks, finds a
  # zombie, and never looks again: the session stays "closing" for good,
  # now and then.  Once a session is stopping, it has no more use for its
  # leader.
  patched = pkgs.elogind.overrideAttrs (old: {
    postPatch = (old.postPatch or "") + ''
      ${pkgs.perl}/bin/perl -0pi -e \
        's/(Unable to determine if leader PID[^\n]*\n\s*)if \(r > 0\)/$1if (r > 0 \&\& !s->stopping)/' \
        src/login/logind-session.c
      grep -q 'r > 0 && !s->stopping' src/login/logind-session.c
    '';
  });
  # (what asks for a login manager without saying so)
  graphical = lib.any (path: lib.attrByPath path false config) [
    [ "services" "xserver" "enable" ]
    [ "services" "displayManager" "enable" ]
    [ "services" "desktopManager" "gnome" "enable" ]
    [ "services" "desktopManager" "plasma6" "enable" ]
    [ "services" "greetd" "enable" ]
    [ "services" "cage" "enable" ]
    [ "programs" "sway" "enable" ]
    [ "programs" "hyprland" "enable" ]
    [ "programs" "niri" "enable" ]
    [ "programs" "labwc" "enable" ]
    [ "programs" "wayfire" "enable" ]
    [ "programs" "dwl" "enable" ]
    [ "programs" "river-classic" "enable" ]
    [ "programs" "miracle-wm" "enable" ]
    # (grants realtime only to processes of active local sessions, which it
    # learns from polkit, which learns it from logind)
    [ "security" "rtkit" "enable" ]
  ];
in

{
  options.services.elogind = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = graphical;
      defaultText = lib.literalMD "whether a display manager, an X server, a Wayland compositor or rtkit is enabled";
      example = true;
      description = ''
        elogind, the standalone logind: user sessions (`/run/user/UID`, seat
        assignment, `loginctl`) and the D-Bus service that polkit, desktop
        environments and `libseat` talk to.  Takes the place of systemd-logind
        in PAM, and in the units that name it.

        On by default where there is a graphical session to manage, which is
        where everything assumes logind; a server has no use for it.
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = patched;
      defaultText = lib.literalMD "`pkgs.elogind` with a fix for sessions that never finish closing";
      description = "The elogind package to use.";
    };
  };

  config = lib.mkIf cfg.enable {
    # The unit keeps systemd's name, which is what other units order
    # themselves after; on the s6 side it is `elogind`.
    systemd.services.systemd-logind = {
      description = "User Login Management";
      wantedBy = [ "multi-user.target" ];
      aliases = [ "dbus-org.freedesktop.login1.service" ];
      requires = [ "dbus.service" ];
      after = [
        "dbus.service"
        "systemd-udevd.service"
      ];
      before = [ "systemd-user-sessions.service" ];
      # Restarting logind takes the graphical session with it.
      restartIfChanged = false;
      stopIfChanged = false;
      path = [
        pkgs.coreutils
        pkgs.util-linux
        pkgs.kmod
      ];
      unitConfig = {
        X-S6-Name = "elogind";
        X-Replace = true;
      };
      serviceConfig = {
        Type = "dbus";
        BusName = "org.freedesktop.login1";
        ExecStart = "${cfg.package}/libexec/elogind";
        Restart = "always";
        RestartSec = 1;
        RuntimeDirectory = "elogind";
        RuntimeDirectoryPreserve = true;
        OOMScoreAdjust = -900;
      };
    };

    # What login sessions are allowed to do, and what the power key does.
    environment.etc."elogind/logind.conf.d/00-nixos.conf".text =
      utils.systemdUtils.lib.settingsToSections logindSettings;

    services.dbus.packages = [ cfg.package ];
    services.udev.packages = [ cfg.package ];

    environment.systemPackages = [ cfg.package ];

    # polkit decides about sessions by asking logind.
    security.polkit.enable = lib.mkDefault true;
  };
}
