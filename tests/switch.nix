# Switching a running system to a new configuration: what changed is
# restarted, what is new is started, what is gone is stopped - and nothing
# else is touched, whatever was added or removed around it.
{
  name = "switch";

  nodes.machine =
    { pkgs, lib, ... }:
    let
      sleep = "${pkgs.coreutils}/bin/sleep infinity";
      daemon =
        version:
        "${pkgs.writeShellScript "t-daemon" ''
          echo ${version} > "/run/$1.version"
          exec ${sleep}
        ''}";
    in
    {
      imports = [ ./configs/minimal-node.nix ];

      environment.systemPackages = [ pkgs.socat ];
      environment.etc."t-file".text = "v1";

      systemd.services = {
        t-keep = {
          wantedBy = [ "multi-user.target" ];
          serviceConfig.ExecStart = "${daemon "v1"} t-keep";
        };
        t-change = {
          wantedBy = [ "multi-user.target" ];
          serviceConfig.ExecStart = "${daemon "v1"} t-change";
        };
        t-remove = {
          wantedBy = [ "multi-user.target" ];
          serviceConfig.ExecStart = "${daemon "v1"} t-remove";
        };
        t-reload = {
          wantedBy = [ "multi-user.target" ];
          reloadIfChanged = true;
          serviceConfig = {
            ExecStart = "${daemon "v1"} t-reload";
            ExecReload = "${pkgs.coreutils}/bin/touch /run/t-reload.reloaded";
          };
        };
        t-pinned = {
          wantedBy = [ "multi-user.target" ];
          restartIfChanged = false;
          serviceConfig.ExecStart = "${daemon "v1"} t-pinned";
        };
        t-oneshot = {
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = "${pkgs.writeShellScript "t-oneshot" "echo v1 > /run/t-oneshot.version"}";
          };
        };
        # (started by hand in the test, to have something for `nixith why`
        # to say about a failure)
        t-broken.serviceConfig = {
          Type = "oneshot";
          ExecStart = "${pkgs.writeShellScript "t-broken" "echo broken-output; exit 3"}";
        };
      };

      specialisation.next.configuration = {
        environment.etc."t-file".text = lib.mkForce "v2";

        systemd.services = {
          t-change.serviceConfig.ExecStart = lib.mkForce "${daemon "v2"} t-change";
          t-remove.enable = false;
          t-reload.serviceConfig.ExecStart = lib.mkForce "${daemon "v2"} t-reload";
          t-pinned.serviceConfig.ExecStart = lib.mkForce "${daemon "v2"} t-pinned";
          t-oneshot.serviceConfig.ExecStart = lib.mkForce "${pkgs.writeShellScript "t-oneshot" "echo v2 > /run/t-oneshot.version"}";

          t-new = {
            wantedBy = [ "multi-user.target" ];
            serviceConfig.ExecStart = "${daemon "v2"} t-new";
          };
          # Things that sit early in the boot order.  Adding them must not
          # disturb anything that is already running.
          t-early = {
            wantedBy = [ "sysinit.target" ];
            before = [ "sysinit.target" ];
            unitConfig.DefaultDependencies = false;
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
              ExecStart = "${pkgs.coreutils}/bin/touch /run/t-early.ran";
            };
          };
          t-echo.serviceConfig.ExecStart = "${pkgs.socat}/bin/socat ACCEPT-FD:3,fork EXEC:${pkgs.coreutils}/bin/cat";
          t-job.serviceConfig = {
            Type = "oneshot";
            ExecStart = "${pkgs.coreutils}/bin/touch /run/t-job.ran";
          };
        };
        systemd.sockets.t-echo = {
          wantedBy = [ "sockets.target" ];
          listenStreams = [ "/run/t-echo.sock" ];
        };
        systemd.timers.t-job = {
          wantedBy = [ "timers.target" ];
          timerConfig.OnActiveSec = "1s";
        };
      };
    };

  testScript =
    { nodes, ... }:
    ''
    init = "${nodes.machine.nixithos.init}"
    machine.start()
    machine.wait_for_unit("multi-user.target")

    def pid(unit):
        return machine.succeed(f"systemctl show -p MainPID --value {unit}").strip()

    def version(unit):
        return machine.succeed(f"cat /run/{unit}.version").strip()

    # (nix-daemon starts on its socket's first client)
    machine.succeed("su -s /bin/sh nobody -c 'nix-store -q --hash /run/current-system'")
    machine.wait_until_succeeds("systemctl is-active nix-daemon.service")
    bystanders = ["t-keep", "dbus", "nix-daemon", "systemd-udevd", "systemd-journald", "nscd", "getty@tty1"]
    before = {u: pid(u) for u in bystanders + ["t-reload", "t-pinned", "t-change"]}
    for u, p in before.items():
        assert p not in ("", "0"), f"{u} is not running"

    with subtest("dry run"):
        out = machine.succeed("/run/current-system/specialisation/next/bin/switch-to-configuration dry-activate 2>&1")
        print(out)
        assert "t-change.service" in out and "t-new.service" in out
        assert pid("t-change") == before["t-change"]

    with subtest("nixith diff"):
        out = machine.succeed("nixith diff --system /run/current-system/specialisation/next 2>&1")
        print(out)

        def row(group, unit):
            # the line of `unit` under the heading that starts with `group`
            lines, here = out.splitlines(), None
            for line in lines:
                if line.startswith("  ") and not line.startswith("    "):
                    here = line.strip()
                elif here is not None and here.startswith(group) and line.strip().startswith(unit + " "):
                    return line.strip()
            raise AssertionError(f"{unit} is not under '{group}' in:\n{out}")

        assert "will be started" in out and "new unit" in row("will be started", "t-new.service")
        assert "no longer in the configuration" in row("will be stopped (", "t-remove.service")
        assert "ExecStart changed" in row("will be stopped, then started", "t-change.service")
        assert "ExecStart changed" in row("will be reloaded", "t-reload.service")
        assert "ExecStart changed" in row("changed, but left running", "t-pinned.service")
        assert "ExecStart changed" in row("will be stopped, then started", "t-oneshot.service")
        assert "t-keep.service" not in out
        assert "not touched:" in out and "Packages" in out
        # it only looks
        assert pid("t-change") == before["t-change"]
        machine.fail("test -e /run/t-new.version")
        # the same system: nothing would change
        assert "nothing would change" in machine.succeed("nixith diff --system /run/current-system")
        # one service cannot be rolled back on its own, and it says why
        err = machine.fail("nixith rollback --service t-keep 2>&1")
        assert "single service" in err

    with subtest("nixith why"):
        out = machine.succeed("nixith why t-keep")
        print(out)
        assert "t-keep.service" in out and "active (running)" in out
        assert f"Manager {init}" in out
        assert "└─ t-keep.service (wants)" in out and "multi-user.target" in out
        assert "started at boot" in out
        # an alias and the bare name
        assert "t-keep.service" in machine.succeed("nixith why t-keep.service")
        assert "no unit" in machine.fail("nixith why t-nosuch 2>&1")

        # a failure: by what, and not wanted by anything
        machine.fail("systemctl start t-broken")
        out = machine.succeed("nixith why t-broken")
        print(out)
        assert "failed" in out and "exited with status 3" in out
        assert "does not pull it in" in out
        machine.wait_until_succeeds("nixith why t-broken | grep broken-output > /dev/null")
        machine.succeed("systemctl reset-failed t-broken")

        # the list
        out = machine.succeed("nixith services --list")
        assert "t-keep.service" in out and "active" in out
        assert "t-broken.service" in machine.succeed("nixith services --list broken")

    with subtest("switch"):
        print(machine.succeed("/run/current-system/specialisation/next/bin/switch-to-configuration test 2>&1"))
        machine.succeed("test \"$(cat /etc/t-file)\" = v2")
        if init == "dinit":
            machine.succeed("test \"$(readlink -f /run/units/.db)\" = \"$(readlink -f /run/current-system/s6-db)\"")
        else:
            machine.succeed("test \"$(readlink -f /run/s6-rc/compiled)\" = \"$(readlink -f /run/current-system/s6-db)/compiled\"")

    with subtest("changed units were restarted"):
        assert version("t-change") == "v2"
        assert pid("t-change") != before["t-change"]
        assert version("t-oneshot") == "v2"

    with subtest("new units were started, removed ones stopped"):
        machine.succeed("systemctl is-active t-new t-echo.socket t-job.timer")
        machine.succeed("test -e /run/t-early.ran")
        assert machine.succeed("echo hi | socat -t 2 - UNIX-CONNECT:/run/t-echo.sock").strip() == "hi"
        machine.wait_until_succeeds("test -e /run/t-job.ran", timeout=30)
        machine.fail("pgrep -f 't-daemon t-remove'")
        machine.fail("systemctl is-active t-remove")

    with subtest("nixith why, after the switch"):
        # a service that waits on its socket: started on demand
        out = machine.succeed("nixith why t-echo.service")
        print(out)
        assert "started on demand by: t-echo.socket" in out
        # the unit that is gone
        assert "no unit" in machine.fail("nixith why t-remove 2>&1")
        # and the diff to where the system came from
        out = machine.succeed("nixith diff --system /run/booted-system 2>&1")
        print(out)
        assert "t-remove.service" in out and "t-new.service" in out

    with subtest("reloadIfChanged and restartIfChanged"):
        machine.succeed("test -e /run/t-reload.reloaded")
        assert pid("t-reload") == before["t-reload"]
        assert pid("t-pinned") == before["t-pinned"]
        assert version("t-pinned") == "v1"

    with subtest("nothing else was touched"):
        for u in bystanders:
            assert pid(u) == before[u], f"{u} was restarted by the switch ({before[u]} -> {pid(u)})"
        failed = machine.succeed("systemctl list-units --failed --no-legend").strip()
        assert failed == "", f"failed units:\n{failed}"
        if init == "dinit":
            # (nothing the switch took down along the way stays down: a target
            # is just "inactive" to systemctl)
            down = machine.succeed("dinitctl list | grep -F '{X}' || true").strip()
            assert down == "", f"dinit services down after the switch:\n{down}"

    with subtest("and back"):
        print(machine.succeed("/run/booted-system/bin/switch-to-configuration test 2>&1"))
        machine.succeed("systemctl is-active t-remove")
        machine.fail("systemctl is-active t-new")
        machine.fail("pgrep -f 't-daemon t-new'")
        machine.fail("test -e /run/t-echo.sock && echo hi | socat -t 2 - UNIX-CONNECT:/run/t-echo.sock")
        assert version("t-change") == "v1"
        for u in bystanders:
            assert pid(u) == before[u], f"{u} was restarted by switching back"

    with subtest("shutdown still works"):
        machine.shutdown()
  '';
}
