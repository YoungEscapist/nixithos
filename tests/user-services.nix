# The services of a user: a supervision tree of their own, started with the
# first session, stopped with the last, driven by `systemctl --user`.
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
          serviceConfig = {
            ExecStart = "${pkgs.writeShellScript "hello" ''
              echo "$GREETING $XDG_RUNTIME_DIR" > "$XDG_RUNTIME_DIR/hello.out"
              exec ${pkgs.coreutils}/bin/sleep infinity
            ''}";
          };
        };
        # starts only when asked for
        on-demand = {
          serviceConfig = {
            Type = "oneshot";
            ExecStart = "${pkgs.coreutils}/bin/touch %t/on-demand.ran";
          };
        };
        echo.serviceConfig.ExecStart = "${pkgs.socat}/bin/socat ACCEPT-FD:3,fork EXEC:${pkgs.coreutils}/bin/cat";
      };
      systemd.user.sockets.echo = {
        wantedBy = [ "sockets.target" ];
        listenStreams = [ "%t/echo.sock" ];
      };
    };

  testScript = ''
    machine.start()
    machine.wait_for_unit("multi-user.target")

    def tty_cmd(cmd):
        machine.send_chars(cmd + "\n")

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
            for c in (
                "cat /run/user-managers/user-1000/run",
                "s6-svstat /run/user-managers/user-1000",
                "tail -n 30 /run/uncaught-logs/current",
                "ps -u alice -o pid,ppid,args | cut -c1-200",
                "ls -la /run/user-managers/.state/1000/service /run/user-managers/.state/1000/s6-rc/servicedirs | head -40",
                "for d in /run/user-managers/.state/1000/service/*; do echo $d; s6-svstat $d; done 2>&1 | head -30",
                "cat /run/user-managers/.state/1000/s6-rc/servicedirs/s6rc-oneshot-runner/run; ls -laR /run/user-managers/.state/1000/s6-rc/servicedirs/s6rc-oneshot-runner | head -40",
            ):
                print("$ " + c)
                print(machine.execute(c)[1])
            raise
        assert machine.succeed("cat /run/user/1000/hello.out").strip() == "hi alice at /home/alice /run/user/1000", machine.succeed("cat /run/user/1000/hello.out")
        # the services are the user's: owner, and no way to the system's
        # (matching on the command line: programs started by a path have the
        # path for a process name)
        machine.wait_until_succeeds("pgrep -u alice -f 'sleep infinity'")

    with subtest("systemctl --user"):
        def user(cmd):
            return machine.succeed(f"su alice -c 'XDG_RUNTIME_DIR=/run/user/1000 {cmd}'")
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
