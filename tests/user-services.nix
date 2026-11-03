# The services of a user: a service manager of their own (an s6 tree, or
# dinit --user with nixithos.init = "dinit"), started with the first session,
# stopped with the last, driven by `systemctl --user`, following a switch.
{
  name = "user-services";

  nodes.machine =
    { pkgs, lib, ... }:
    {
      imports = [ ./configs/minimal-node.nix ];

      services.elogind.enable = true;
      environment.systemPackages = [ pkgs.socat ];

      users.users.alice = {
        isNormalUser = true;
        password = "wonderland";
      };

      systemd.user.services = {
        hello = {
          wantedBy = [ "default.target" ];
          environment.GREETING = "hi %u at %h";
          serviceConfig.ExecStart = "${pkgs.writeShellScript "hello" ''
            echo "$GREETING $XDG_RUNTIME_DIR" > "$XDG_RUNTIME_DIR/hello.out"
            exec ${pkgs.coreutils}/bin/sleep infinity
          ''}";
        };
        # starts only when asked for
        on-demand = {
          serviceConfig = {
            Type = "oneshot";
            ExecStart = "${pkgs.coreutils}/bin/touch %t/on-demand.ran";
          };
        };
        echo.serviceConfig.ExecStart = "${pkgs.socat}/bin/socat ACCEPT-FD:3,fork EXEC:${pkgs.coreutils}/bin/cat";
        # pipewire and wireplumber: pw comes with its socket, wp is WantedBy=
        # pw and requires it too (the want is lost to the ordering cycle)
        pw.serviceConfig.ExecStart = "${pkgs.socat}/bin/socat ACCEPT-FD:3,fork EXEC:${pkgs.coreutils}/bin/cat";
        wp = {
          wantedBy = [ "pw.service" ];
          requires = [ "pw.service" ];
          after = [ "pw.service" ];
          serviceConfig.ExecStart = "${pkgs.coreutils}/bin/sleep 1000011";
        };
        # what a timer runs
        tick.serviceConfig = {
          Type = "oneshot";
          ExecStart = "${pkgs.writeShellScript "tick" ''echo tick >> "$XDG_RUNTIME_DIR/tick.count"''}";
        };
        # OnFailure=
        breaks = {
          onFailure = [ "noticed.service" ];
          serviceConfig.ExecStart = "${pkgs.coreutils}/bin/false";
        };
        noticed.serviceConfig = {
          Type = "oneshot";
          ExecStart = "${pkgs.coreutils}/bin/touch %t/noticed";
        };
        # stays as it is through the switch
        steady = {
          wantedBy = [ "default.target" ];
          serviceConfig.ExecStart = "${pkgs.coreutils}/bin/sleep 1000001";
        };
        gone = {
          wantedBy = [ "default.target" ];
          serviceConfig.ExecStart = "${pkgs.coreutils}/bin/sleep 1000002";
        };
      };
      systemd.user.sockets.echo = {
        wantedBy = [ "sockets.target" ];
        listenStreams = [ "%t/echo.sock" ];
      };
      systemd.user.sockets.pw = {
        wantedBy = [ "sockets.target" ];
        listenStreams = [ "%t/pw.sock" ];
      };
      systemd.user.timers.tick = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnActiveSec = "1s";
          OnUnitActiveSec = "2s";
        };
      };

      # a switch while the user's manager runs (user-manager switch-all)
      specialisation.next.configuration = {
        systemd.user.services = {
          hello.environment.GREETING = lib.mkForce "hello %u at %h";
          gone.enable = false;
          fresh = {
            wantedBy = [ "default.target" ];
            serviceConfig.ExecStart = "${pkgs.coreutils}/bin/sleep 1000003";
          };
        };
      };
    };

  testScript =
    { nodes, ... }:
    ''
    init = "${nodes.machine.nixithos.init}"
    machine.start()
    machine.wait_for_unit("multi-user.target")

    def tty_cmd(cmd):
        machine.send_chars(cmd + "\n")

    st = "/run/user-managers/.state/1000"

    # what the user's manager is up to, for a test that failed
    def diagnose():
        cmds = [
            "cat /run/user-managers/user-1000/run",
            "s6-svstat /run/user-managers/user-1000",
            # (what the user-managers service says: s6-svscan's catch-all log,
            # or with dinit the one of services without a logger, and dinit's)
            "tail -n 30 /run/uncaught-logs/current /run/uncaught-logs/services /run/uncaught-logs/dinit 2>/dev/null",
            "ps -u alice -o pid,ppid,pgid,stat,args | cut -c1-200",
            f"ls -la {st} {st}/units",
        ]
        if init == "dinit":
            cmds += [
                f"su alice -c 'dinitctl -p {st}/dinitctl list'",
                f"tail -n 60 {st}/dinit.log",
                f"for f in {st}/units/.sv/*; do echo \"$f: $(cat $f)\"; done",
                f"for u in {st}/units/*/; do echo \"$u: $(cat $u/state $u/result 2>/dev/null | tr '\\n' ' ')\"; done",
            ]
        else:
            cmds += [
                f"ls -la {st}/service {st}/s6-rc/servicedirs | head -40",
                f"for d in {st}/service/*; do echo $d; s6-svstat $d; done 2>&1 | head -30",
            ]
        for c in cmds:
            print("$ " + c)
            print(machine.execute(c)[1])

    with subtest("no manager before anyone logs in"):
        machine.fail("test -d /run/user-managers/user-1000")

    with subtest("a session starts the user's manager and its services"):
        machine.wait_until_tty_matches("1", "login: ")
        machine.send_chars("alice\n")
        machine.wait_until_tty_matches("1", "Password: ")
        machine.send_chars("wonderland\n")
        machine.wait_until_succeeds("test -d /run/user-managers/user-1000")
        try:
            machine.wait_until_succeeds("test -s /run/user/1000/hello.out", timeout=40)
        except Exception:
            diagnose()
            raise
        assert machine.succeed("cat /run/user/1000/hello.out").strip() == "hi alice at /home/alice /run/user/1000", machine.succeed("cat /run/user/1000/hello.out")
        # the services are the user's: owner, and no way to the system's
        # (matching on the command line: programs started by a path have the
        # path for a process name)
        machine.wait_until_succeeds("pgrep -u alice -f 'sleep infinity'")

    def user(cmd):
        try:
            return machine.succeed(f"su alice -c 'XDG_RUNTIME_DIR=/run/user/1000 {cmd}'", timeout=120)
        except Exception:
            diagnose()
            raise

    with subtest("systemctl --user"):
        print(user("systemctl --user list-units --no-legend"))
        user("systemctl --user is-active hello.service")
        user("systemctl --user start on-demand.service")
        machine.succeed("test -e /run/user/1000/on-demand.ran")
        pid = user("systemctl --user show -p MainPID --value hello").strip()
        user("systemctl --user restart hello")
        assert user("systemctl --user show -p MainPID --value hello").strip() != pid
        user("systemctl --user stop hello")
        machine.fail("su alice -c 'XDG_RUNTIME_DIR=/run/user/1000 systemctl --user is-active hello'")
        user("systemctl --user start hello")

    with subtest("user sockets"):
        out = machine.succeed("echo ping | su alice -c 'socat -t 3 - UNIX-CONNECT:/run/user/1000/echo.sock'").strip()
        assert out == "ping", out
        # started by the socket, and again once stopped
        user("systemctl --user is-active echo.service")
        user("systemctl --user stop echo.service")
        out = machine.succeed("echo pong | su alice -c 'socat -t 3 - UNIX-CONNECT:/run/user/1000/echo.sock'").strip()
        assert out == "pong", out
        # what a socket-started service wants comes with it (wireplumber with
        # pipewire), also when the want is lost to an ordering cycle
        machine.fail("pgrep -u alice -f 'sleep 1000011'")
        out = machine.succeed("echo pw | su alice -c 'socat -t 3 - UNIX-CONNECT:/run/user/1000/pw.sock'").strip()
        assert out == "pw", out
        machine.wait_until_succeeds("pgrep -u alice -f 'sleep 1000011'", timeout=30)

    with subtest("timers and OnFailure="):
        machine.wait_until_succeeds("test $(wc -l < /run/user/1000/tick.count) -ge 2", timeout=40)
        user("systemctl --user is-active tick.timer")
        user("systemctl --user start breaks.service || true")
        machine.wait_until_succeeds("test -e /run/user/1000/noticed", timeout=30)
        assert user("systemctl --user is-failed breaks.service || true").strip() == "failed"

    with subtest("a switch reaches the user's manager"):
        def upid(unit):
            return user(f"systemctl --user show -p MainPID --value {unit}").strip()
        before = {u: upid(u) for u in ("hello", "steady", "gone")}
        assert all(p not in ("", "0") for p in before.values()), before
        print(machine.succeed("/run/current-system/specialisation/next/bin/switch-to-configuration test 2>&1"))
        if init == "dinit":
            machine.succeed("test \"$(readlink -f /run/user-managers/.state/1000/db)\" = \"$(readlink -f /run/current-system/s6-db)/user\"")
        machine.wait_until_succeeds("grep -q '^hello alice' /run/user/1000/hello.out", timeout=30)
        assert upid("hello") != before["hello"]
        assert upid("steady") == before["steady"], "an unchanged service was restarted"
        machine.wait_until_succeeds("pgrep -u alice -f 'sleep 1000003'", timeout=30)
        user("systemctl --user is-active fresh.service")
        machine.wait_until_fails("pgrep -u alice -f 'sleep 1000002'", timeout=30)
        # what does not change goes on working
        out = machine.succeed("echo again | su alice -c 'socat -t 3 - UNIX-CONNECT:/run/user/1000/echo.sock'").strip()
        assert out == "again", out

    with subtest("session bus"):
        user("busctl --user list >/dev/null 2>&1 || dbus-send --session --print-reply --dest=org.freedesktop.DBus / org.freedesktop.DBus.ListNames")

    with subtest("environment import"):
        user("FOO=bar systemctl --user import-environment FOO")
        assert "FOO=bar" in user("systemctl --user show-environment")

    with subtest("the last logout stops it"):
        machine.send_chars("exit\n")
        machine.wait_until_fails("test -d /run/user-managers/user-1000", timeout=90)
        # nothing of the user's is left, and the directory is gone with it
        machine.wait_until_fails("pgrep -u alice", timeout=30)
        machine.wait_until_fails("test -e /run/user/1000", timeout=30)

    with subtest("a new session brings it back"):
        # (another console: the first one still shows the earlier prompts)
        machine.send_key("alt-f2")
        machine.wait_until_tty_matches("2", "login: ")
        machine.send_chars("alice\n")
        machine.wait_until_tty_matches("2", "Password: ")
        machine.send_chars("wonderland\n")
        machine.wait_until_succeeds("test -s /run/user/1000/hello.out", timeout=60)
        machine.wait_until_succeeds("pgrep -u alice -f 'sleep infinity'")

    with subtest("a lingering user has a manager without a session"):
        machine.send_chars("exit\n")
        machine.wait_until_fails("test -d /run/user-managers/user-1000", timeout=90)
        machine.wait_until_fails("pgrep -u alice", timeout=30)
        machine.succeed("loginctl enable-linger alice")
        machine.wait_until_succeeds("test -d /run/user-managers/user-1000", timeout=30)
        machine.wait_until_succeeds("test -s /run/user/1000/hello.out", timeout=60)
        # and it is not stopped for want of a session
        machine.sleep(10)
        machine.succeed("test -d /run/user-managers/user-1000 && pgrep -u alice -f 'sleep infinity'")
        machine.succeed("loginctl disable-linger alice")
        machine.wait_until_fails("test -d /run/user-managers/user-1000", timeout=90)
        machine.wait_until_fails("pgrep -u alice", timeout=30)
  '';
}
