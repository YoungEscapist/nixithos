# Logging in: on a virtual console through agetty/login/PAM, and over SSH
# from a second machine.
{
  name = "login";

  nodes.server =
    { pkgs, ... }:
    {
      imports = [ ./configs/minimal-node.nix ];

      services.openssh.enable = true;
      users.users.alice = {
        isNormalUser = true;
        password = "wonderland";
      };
      users.users.root.openssh.authorizedKeys.keyFiles = [ ./configs/ssh-test-key.pub ];
    };

  nodes.client =
    { pkgs, ... }:
    {
      imports = [ ./configs/minimal-node.nix ];
      environment.etc."ssh-test-key" = {
        source = ./configs/ssh-test-key;
        mode = "0600";
      };
    };

  testScript = ''
    start_all()
    server.wait_for_unit("multi-user.target")
    client.wait_for_unit("multi-user.target")

    with subtest("console login"):
        server.wait_until_tty_matches("1", "login: ")
        server.send_chars("alice\n")
        server.wait_until_tty_matches("1", "Password: ")
        server.send_chars("wonderland\n")
        server.wait_until_succeeds("pgrep -u alice bash")
        server.send_chars("id -un > /tmp/whoami; tty > /tmp/tty\n")
        server.wait_for_file("/tmp/whoami")
        assert server.succeed("cat /tmp/whoami").strip() == "alice"
        assert server.succeed("cat /tmp/tty").strip() == "/dev/tty1"
        # su goes through the setuid wrappers and PAM
        server.succeed("su alice -c 'test -u /run/wrappers/bin/su || stat -c %a /run/wrappers/bin/su'")
        server.send_chars("exit\n")
        # getty comes back for the next login
        server.wait_until_fails("pgrep -u alice bash")
        server.wait_until_succeeds("pgrep -f 'agetty.*tty1'")

    with subtest("sshd"):
        server.wait_for_unit("sshd.service")
        server.wait_for_open_port(22)
        client.wait_until_succeeds("ping -c1 -W1 server")
        out = client.succeed(
            # (-n: the standard input of the test's shell is its console;
            # a timeout, so that a hang is a failure, not an hour)
            "timeout 60 ssh -n -o BatchMode=yes -i /etc/ssh-test-key -o StrictHostKeyChecking=no "
            "-o UserKnownHostsFile=/dev/null root@server 'echo hello from $(hostname); cat /proc/1/comm'"
        )
        print(out)
        assert "hello from server" in out
        assert "s6-svscan" in out
        # sessions do not die with a reload of the daemon
        server.succeed("systemctl reload sshd && systemctl is-active sshd")

    with subtest("no failed units"):
        for m in (server, client):
            failed = m.succeed("systemctl list-units --failed --no-legend").strip()
            assert failed == "", f"failed units on {m.name}:\n{failed}"
  '';
}
