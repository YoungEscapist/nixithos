# User-session systemd D-Bus compatibility, independent of the system init.
{ config, lib, pkgs, ... }:
let cfg = config.nixithos.compat.systemd;
in {
  options.nixithos.compat.systemd.enable = lib.mkEnableOption
    "the user-session systemd D-Bus adapter and delegated transient user units";
  config = lib.mkIf cfg.enable {
    assertions = [ {
      assertion = config.s6.userManager.enable;
      message = "systemd user compatibility requires s6.userManager.enable.";
    } ];
    environment.etc."units/systemd-compat".text = "user cgroup delegation enabled\n";
    systemd.user.services.systemd1-bus = {
      description = "systemd user D-Bus compatibility";
      wantedBy = [ "default.target" ];
      requires = [ "dbus.service" ];
      after = [ "dbus.service" ];
      environment.SYSTEMD1_BUS_SYSTEMCTL = "${config.systemd.package}/bin/systemctl";
      serviceConfig = {
        Type = "dbus";
        BusName = "org.freedesktop.systemd1";
        ExecStart = lib.getExe (pkgs.callPackage ../../pkgs/systemd-shim/systemd1-bus.nix { });
        Restart = "on-failure";
      };
    };
  };
}
