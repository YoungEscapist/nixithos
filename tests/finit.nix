# Initial native Finit integration: real PID 1, normal NixOS units and shutdown.
{
  name = "finit-smoke";
  nodes.machine = { pkgs, ... }: {
    imports = [ ./configs/minimal-node.nix ];
    systemd.services.finit-probe = {
      wantedBy = [ "multi-user.target" ];
      after = [ "dbus.service" ];
      requires = [ "dbus.service" ];
      serviceConfig.ExecStart = "${pkgs.coreutils}/bin/sleep infinity";
    };
  };
  testScript = ''
    machine.start()
    machine.wait_for_unit("multi-user.target")
    pid1 = machine.succeed("readlink /proc/1/exe").strip()
    assert pid1.endswith("-finit-4.17/bin/finit"), pid1
    machine.succeed("test -S /run/dbus/system_bus_socket")
    machine.succeed("systemctl is-active dbus.service finit-probe.service")
    import json
    names = dict(line.split("\t") for line in machine.succeed("cat /run/units/.db/finit-names.tsv").strip().splitlines())
    names = {native: atom for atom, native in names.items()}
    state = json.loads(machine.succeed("initctl -j status"))
    for entry in state:
        if entry["status"] not in ("running", "done", "stopped"):
            print("FINIT_PENDING", names.get(entry["identity"], entry["identity"]), entry["status"], entry.get("condition"))
    machine.wait_until_succeeds("test ! -e /run/units/.booting", timeout=30)
    machine.succeed("systemctl is-system-running")
    machine.shutdown()
  '';
}
