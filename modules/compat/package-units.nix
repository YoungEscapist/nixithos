# Units that NixOS expects to find inside a package (`systemd.packages`).
# Packages built without systemd support often do not install their unit
# files, so the ones that matter are defined here.  `X-Replace` makes each
# definition complete in itself: it is used as is, whether or not the package
# happens to ship a unit of the same name.
{
  config,
  lib,
  pkgs,
  ...
}:

{
  config = lib.mkMerge [
    (lib.mkIf config.services.fstrim.enable {
      systemd.services.fstrim = {
        description = "Discard unused blocks on filesystems from /etc/fstab";
        unitConfig = {
          X-Replace = true;
          ConditionVirtualization = "!container";
        };
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${pkgs.util-linux}/sbin/fstrim --listed-in /etc/fstab:/proc/self/mountinfo --verbose --quiet-unsupported";
          IOSchedulingClass = "idle";
        };
      };
      systemd.timers.fstrim = {
        description = "Discard unused filesystem blocks once a week";
        timerConfig = {
          AccuracySec = lib.mkDefault "1h";
          Persistent = lib.mkDefault true;
          RandomizedDelaySec = lib.mkDefault "100min";
        };
      };
    })
  ];
}
