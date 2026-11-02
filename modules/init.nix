# Which init system runs the machine.
#
#   s6      s6-linux-init as PID 1, s6-rc driving the services (../s6)
#   dinit   dinit as PID 1 and service manager (../dinit)
#
# Everything else is the same for both: the units NixOS generates, the unit
# compiler (unitc) that turns them into the services of either, the runtime
# that starts a unit's processes, the systemctl and journalctl that drive
# them, the loggers, the fd holder of sockets, the managers of users.
{ lib, ... }:

{
  options.nixithos.init = lib.mkOption {
    type = lib.types.enum [
      "s6"
      "dinit"
    ];
    default = "s6";
    example = "dinit";
    description = ''
      The init system and service manager: `s6` (s6-linux-init and s6-rc)
      or `dinit`.  The units of `systemd.services` and friends work the same
      on both; a running system goes from one to the other at the next boot.
    '';
  };
}
