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

  testScript = ''
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

    with subtest("switch"):
        print(machine.succeed("/run/current-system/specialisation/next/bin/switch-to-configuration test 2>&1"))
        machine.succeed("test \"$(cat /etc/t-file)\" = v2")
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
