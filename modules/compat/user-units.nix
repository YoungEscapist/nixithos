# The units of `systemd.user.*`, and the targets a user's manager provides.
#
# Upstream implements these in system/boot/systemd/user.nix, of which only
# the option declarations are imported (../module-list.nix).  What is done
# here is what its config half did: turn the option tree into units, and
# generate the unit directory.  The directory is compiled into a service
# database for each user's supervision tree, like the system's
# (../s6/default.nix, ../../pkgs/user-manager).
{
  config,
  lib,
  pkgs,
  utils,
  ...
}:

let
  cfg = config.systemd.user;

  inherit (utils.systemdUtils.lib)
    generateUnits
    targetToUnit
    serviceToUnit
    socketToUnit
    timerToUnit
    pathToUnit
    sliceToUnit
    ;

  # What upstream does for systemd.user.tmpfiles: the rules are files that
  # user-tmpfiles.d finds through $XDG_CONFIG_DIRS (in the system profile for
  # everybody's, in the user's own for theirs).
  writeTmpfiles =
    {
      rules,
      user ? null,
    }:
    let
      suffix = lib.optionalString (user != null) "-${user}";
    in
    pkgs.writeTextFile {
      name = "nixos-user-tmpfiles.d${suffix}";
      destination = "/etc/xdg/user-tmpfiles.d/00-nixos${suffix}.conf";
      text = ''
        # This file is created automatically and should not be modified.
        # Please change the options ‘systemd.user.tmpfiles’ instead.
        ${lib.concatStringsSep "\n" rules}
      '';
    };

  # A target that is only started on purpose and stopped when nothing wants
  # it any more: the pieces of a graphical session.
  session = description: {
    inherit description;
    unitConfig = {
      RefuseManualStart = true;
      StopWhenUnneeded = true;
    };
  };
in

{
  config = {
    systemd.user.units =
      lib.mapAttrs' (n: v: lib.nameValuePair "${n}.path" (pathToUnit v)) cfg.paths
      // lib.mapAttrs' (n: v: lib.nameValuePair "${n}.service" (serviceToUnit v)) cfg.services
      // lib.mapAttrs' (n: v: lib.nameValuePair "${n}.slice" (sliceToUnit v)) cfg.slices
      // lib.mapAttrs' (n: v: lib.nameValuePair "${n}.socket" (socketToUnit v)) cfg.sockets
      // lib.mapAttrs' (n: v: lib.nameValuePair "${n}.target" (targetToUnit v)) cfg.targets
      // lib.mapAttrs' (n: v: lib.nameValuePair "${n}.timer" (timerToUnit v)) cfg.timers;

    # Timers of services that have a ‘startAt’.
    systemd.user.timers =
      lib.mapAttrs (name: service: {
        wantedBy = [ "timers.target" ];
        timerConfig.OnCalendar = service.startAt;
      }) (lib.filterAttrs (_: service: service.startAt != [ ]) cfg.services)
      // lib.optionalAttrs cfg.tmpfiles.enable {
        systemd-tmpfiles-clean = {
          description = "Periodic Cleanup of User's Temporary Files and Directories";
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnStartupSec = lib.mkDefault "5min";
            OnUnitActiveSec = lib.mkDefault "1d";
          };
        };
      };

    # tmpfiles.d for the user (systemd ships these two).  What they act on are
    # the rules of systemd.user.tmpfiles, which the upstream module installs
    # as user-tmpfiles.d files where $XDG_CONFIG_DIRS finds them.
    # (systemd.user.tmpfiles.enable = false takes the units away: with nothing
    # to start them they would be there, "static", for `is-enabled` to find)
    systemd.user.services = lib.optionalAttrs cfg.tmpfiles.enable {
      systemd-tmpfiles-setup = {
        description = "Create User Files and Directories";
        wantedBy = [ "basic.target" ];
        unitConfig.ConditionUser = lib.mkDefault "!@system";
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = lib.mkDefault "${config.systemd.package}/bin/systemd-tmpfiles --user --create --remove";
        };
      };
      systemd-tmpfiles-clean = {
        description = "Cleanup of User's Temporary Files and Directories";
        unitConfig.ConditionUser = lib.mkDefault "!@system";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = lib.mkDefault "${config.systemd.package}/bin/systemd-tmpfiles --user --clean";
          SuccessExitStatus = "DATAERR";
        };
      };
    };


    environment.systemPackages = lib.optional (cfg.tmpfiles.rules != [ ]) (writeTmpfiles {
      inherit (cfg.tmpfiles) rules;
    });

    users.users = lib.mapAttrs (user: cfg': {
      packages = lib.optional (cfg'.rules != [ ]) (writeTmpfiles {
        inherit (cfg') rules;
        inherit user;
      });
    }) cfg.tmpfiles.users;

    system.userActivationScripts.tmpfiles = ''
      ${config.systemd.package}/bin/systemd-tmpfiles --user --create --remove
    '';

    # What systemd ships for its user instances.
    systemd.user.targets = {
      default = {
        description = "Main User Target";
        requires = [ "basic.target" ];
        after = [ "basic.target" ];
        unitConfig.AllowIsolate = true;
      };
      basic = {
        description = "Basic System";
        wants = [
          "sockets.target"
          "timers.target"
          "paths.target"
        ];
        after = [
          "sockets.target"
          "timers.target"
          "paths.target"
        ];
      };
      sockets.description = "Sockets";
      timers.description = "Timers";
      paths.description = "Paths";
      bluetooth.description = "Bluetooth";
      printer.description = "Printer";
      smartcard.description = "Smart Card";
      sound.description = "Sound Card";
      exit = {
        description = "Exit the Session";
        unitConfig.AllowIsolate = true;
      };
      shutdown.description = "Shutdown";
      graphical-session = session "Current graphical user session";
      graphical-session-pre = session "Session services which should run early before the graphical session is brought up";
      xdg-desktop-autostart = {
        description = "Startup of XDG autostart applications";
        unitConfig.RefuseManualStart = true;
      };
    };

    system.build.userUnits = generateUnits {
      type = "user";
      inherit (cfg) units;
      upstreamUnits = [ ];
      upstreamWants = [ ];
      packages = config.systemd.packages;
      package = config.systemd.package;
    };

    environment.etc."systemd/user".source = config.system.build.userUnits;
  };
}
