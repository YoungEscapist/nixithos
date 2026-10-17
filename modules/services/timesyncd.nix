# Network time: `services.timesyncd` (on by default in NixOS, off in
# containers) with a small SNTP client in the place of systemd-timesyncd.
#
# It is configured the way timesyncd is: the options of the upstream module
# (`servers`, `fallbackServers`, `extraConfig`) end up in
# /etc/systemd/timesyncd.conf, which unit-sntp reads.  It keeps the clock
# from falling behind the last synchronization on machines that have no
# battery-backed one, and says so with /run/systemd/timesync/synchronized,
# which is what `systemd-time-wait-sync` and the like wait for.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.timesyncd;
in

{
  config = lib.mkIf cfg.enable {
    users.users.systemd-timesync = {
      uid = config.ids.uids.systemd-timesync;
      group = "systemd-timesync";
    };
    users.groups.systemd-timesync.gid = config.ids.gids.systemd-timesync;

    environment.etc."systemd/timesyncd.conf".text =
      ''
        [Time]
      ''
      + lib.optionalString (cfg.servers != null) ''
        NTP=${lib.concatStringsSep " " cfg.servers}
      ''
      + lib.optionalString (cfg.fallbackServers != null) ''
        FallbackNTP=${lib.concatStringsSep " " cfg.fallbackServers}
      ''
      + cfg.extraConfig;

    systemd.services.systemd-timesyncd = {
      description = "Network Time Synchronization";
      wantedBy = [
        "sysinit.target"
        "time-sync.target"
      ];
      before = [
        "time-set.target"
        "sysinit.target"
        "shutdown.target"
      ];
      conflicts = [ "shutdown.target" ];
      aliases = [ "dbus-org.freedesktop.timesync1.service" ];
      restartTriggers = [ config.environment.etc."systemd/timesyncd.conf".source ];
      unitConfig = {
        DefaultDependencies = false;
        X-S6-Name = "timesyncd";
        ConditionVirtualization = "!container";
      };
      serviceConfig = {
        ExecStart = "${pkgs.nixithos.unitTools}/bin/unit-sntp";
        User = "systemd-timesync";
        Group = "systemd-timesync";
        # to set the clock and nothing else
        CapabilityBoundingSet = [ "CAP_SYS_TIME" ];
        AmbientCapabilities = [ "CAP_SYS_TIME" ];
        StateDirectory = "systemd/timesync";
        RuntimeDirectory = "systemd/timesync";
        RuntimeDirectoryPreserve = "yes";
        Restart = "always";
        RestartSec = 5;
      };
    };
  };
}
