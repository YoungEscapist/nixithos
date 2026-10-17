# Login sessions through elogind: PAM registers the session, /run/user/UID
# exists while it does, and it goes away with the last logout.
{
  name = "elogind";

  nodes.machine =
    { pkgs, ... }:
    {
      imports = [ ./configs/minimal-node.nix ];

      services.elogind.enable = true;
      users.users.alice = {
        isNormalUser = true;
        password = "wonderland";
      };

      # PAMName=: a service that runs in a session of its own, as cage's does
      users.users.bob.isNormalUser = true;
      systemd.services.pam-session = {
        wantedBy = [ "multi-user.target" ];
        after = [ "systemd-logind.service" ];
        serviceConfig = {
          User = "bob";
          PAMName = "login";
          ExecStart = pkgs.writeShellScript "pam-session" ''
            echo "$XDG_RUNTIME_DIR $XDG_SESSION_ID" > /tmp/pam-session
            exec ${pkgs.coreutils}/bin/sleep infinity
          '';
        };
      };
    };

  testScript = ''
    machine.start()
    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("systemd-logind.service")

    with subtest("the bus name is there"):
        machine.succeed("busctl --system status org.freedesktop.login1 >/dev/null 2>&1 || loginctl list-sessions")

    with subtest("PAMName= gives a service a session"):
        bob = machine.succeed("id -u bob").strip()
        machine.wait_for_file("/tmp/pam-session")
        out = machine.succeed("cat /tmp/pam-session").split()
        assert len(out) == 2 and out[0] == f"/run/user/{bob}", out
        machine.succeed(f"test -d /run/user/{bob}")
        machine.succeed("loginctl list-sessions --no-legend | grep -q bob")
        machine.succeed("systemctl stop pam-session")
        machine.wait_until_fails("loginctl list-sessions --no-legend | grep -q bob", timeout=60)

    with subtest("logging in creates a session and a runtime directory"):
        machine.wait_until_tty_matches("1", "login: ")
        machine.send_chars("alice\n")
        machine.wait_until_tty_matches("1", "Password: ")
        machine.send_chars("wonderland\n")
        machine.wait_until_succeeds("loginctl list-sessions --no-legend | grep -q alice")
        uid = machine.succeed("id -u alice").strip()
        machine.succeed(f"test -d /run/user/{uid}")
        machine.send_chars("echo $XDG_RUNTIME_DIR $XDG_SESSION_ID > /tmp/xdg\n")
        machine.wait_for_file("/tmp/xdg")
        out = machine.succeed("cat /tmp/xdg").split()
        assert out[0] == f"/run/user/{uid}", out
        print(machine.succeed("loginctl list-sessions; loginctl list-seats"))

    with subtest("logging out removes them"):
        machine.send_chars("exit\n")
        for _ in range(18):
            if "alice" not in machine.execute("loginctl list-sessions --no-legend")[1]:
                break
            machine.sleep(5)
        else:
            for c in (
                "loginctl list-sessions; loginctl show-session 1",
                "ps -eo pid,ppid,user,stat,cgroup:20,args | grep -v ' \\[' | tail -40 | cut -c1-200",
                "cat /sys/fs/cgroup/1/cgroup.procs /sys/fs/cgroup/1/cgroup.events",
                "ls -laR /run/user-managers/.sessions; cat /run/user-managers/.sessions/*.idle",
                "ls -la /run/systemd/sessions /run/systemd/users",
                "grep -E 'session|Session' /var/log/s6/syslogd/current | grep -v 'Got message\\|Sent message\\|Registering' | tail -n 20 | cut -c1-220",
                "tail -n 20 /var/log/s6/syslogd/current | cut -c1-200",
            ):
                print("$ " + c)
                print(machine.execute(c)[1])
            raise Exception("the session did not close")
        machine.wait_until_fails(f"test -d /run/user/{uid}")
  '';
}
