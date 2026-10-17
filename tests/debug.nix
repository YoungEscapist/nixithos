# A scratch test for poking at a VM; not part of the suite (`nix-build -A wip.debug`).
{ lib, ... }:
{
  imports = [ ./switch.nix ];
  name = lib.mkForce "debug";

  testScript = lib.mkForce ''
    machine.start()
    machine.wait_for_unit("multi-user.target")
    print(machine.execute(r"""
      db=$(readlink -f /run/booted-system/s6-db)
      up=" $(s6-rc -a list | tr '\n' ' ') "
      echo "up: $(s6-rc -a list | wc -l)"
      for a in $(s6-rc -a list); do
        for d in $(s6-rc-db -c $db/compiled dependencies $a); do
          case "$up" in *" $d "*) ;; *) echo "$a needs $d which is not up";; esac
        done
      done
      echo ---compiled-boot
      for a in $(s6-rc -a list); do
        for d in $(s6-rc-db -c $db/compiled-boot dependencies $a); do
          case "$up" in *" $d "*) ;; *) echo "$a needs (boot) $d which is not up";; esac
        done
      done
    """)[1])
  '';
}
