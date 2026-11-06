# Synchronous control must include delayed readiness and stop hooks.
{
  name = "finit-control";
  nodes.machine = { pkgs, ... }: {
    imports = [ ./configs/minimal-node.nix ];
    systemd.services.control-probe = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "notify";
        NotifyAccess = "all";
        ExecStart = pkgs.writeShellScript "control-probe" ''
          sleep 1
          touch /run/control-ready
          systemd-notify --ready
          exec ${pkgs.coreutils}/bin/sleep infinity
        '';
        ExecStop = pkgs.writeShellScript "control-stop" ''
          sleep 2
          touch /run/control-stopped
        '';
      };
    };
  };
  testScript = ''
    machine.start()
    try:
        machine.wait_until_succeeds("systemctl is-active multi-user.target", timeout=45)
    except Exception:
        print(machine.succeed("initctl -j status"))
        print(machine.succeed("ps axf"))
        raise
    machine.succeed("systemctl is-active control-probe.service")
    machine.succeed("systemctl stop control-probe.service && test -e /run/control-stopped")
    machine.fail("systemctl is-active control-probe.service")
    machine.succeed("systemctl start control-probe.service && systemctl is-active control-probe.service")
    pid = machine.succeed("systemctl show -p MainPID --value control-probe.service").strip()
    machine.succeed("rm /run/control-stopped && systemctl restart control-probe.service && test -e /run/control-stopped && systemctl is-active control-probe.service")
    new_pid = machine.succeed("systemctl show -p MainPID --value control-probe.service").strip()
    assert pid != new_pid and int(new_pid) > 1, (pid, new_pid)
    supervisor = machine.succeed("cat /run/units/.sv/control-probe").split()[4]
    machine.succeed("systemctl try-restart control-probe.service && systemctl is-active control-probe.service")
    assert machine.succeed("cat /run/units/.sv/control-probe").split()[4] == supervisor
    restarted_pid = machine.succeed("systemctl show -p MainPID --value control-probe.service").strip()
    assert restarted_pid != new_pid and int(restarted_pid) > 1
    machine.fail("finitctl start nonexistent-unit")
    machine.fail("finitctl status nonexistent-unit")
    machine.succeed("test $(finitctl list | wc -l) -eq $(wc -l < /run/units/.db/finit-names.tsv)")
    machine.succeed("rm /run/control-stopped && finitctl stop --no-wait control-probe && test ! -e /run/control-stopped")
    machine.wait_until_succeeds("test -e /run/control-stopped")
    machine.succeed("finitctl stop control-probe && rm /run/control-ready && finitctl start control-probe && test -e /run/control-ready && systemctl is-active control-probe.service")
    machine.shutdown()
  '';
}
