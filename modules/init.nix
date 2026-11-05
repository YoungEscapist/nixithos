# Which init system runs the machine.
#
#   s6      s6-linux-init as PID 1, s6-rc driving the services (../s6)
#   dinit   dinit as PID 1 and service manager (../dinit)
#   runit   runit as PID 1, runsvdir and runsv supervising the processes, and
#           unit-rc, which knows what starts after what (../runit)
#   openrc  OpenRC as PID 1 and service manager, on scripts unitc writes for
#           it (../openrc)
#
#   finit   experimental native Finit tasks, conditions and supervision
#           (../finit; see docs/finit.md)
#
# Everything else is the same for all: the units NixOS generates, the unit
# compiler (unitc) that turns them into the services of either, the runtime
# that starts a unit's processes, the systemctl and journalctl that drive
# them, the loggers, the fd holder of sockets.  The managers of users are of
# the same kind as the system's: s6 trees, or dinit --user; under runit and
# openrc and finit they are s6 trees, whose programs are on the machine anyway (the loggers, the fd
# holder).
{ lib, ... }:

{
  options.nixithos.init = lib.mkOption {
    type = lib.types.enum [
      "s6"
      "dinit"
      "runit"
      "openrc"
      "finit"
    ];
    default = "s6";
    example = "dinit";
    description = ''
      The init system and service manager: `s6` (s6-linux-init and s6-rc),
      `dinit`, `runit` (runit, with unit-rc for the dependencies), `openrc`,
      or experimental `finit` (boot-only; see docs/finit.md).
      The stable backends share the units of `systemd.services` and friends;
      a running system changes its init at the next boot. The Finit unit
      translation and control interface are still experimental.
    '';
  };
}
