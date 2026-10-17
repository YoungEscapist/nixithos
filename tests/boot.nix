# The system boots on s6, reaches its default target with nothing failed,
# and shuts down cleanly.
{
  name = "boot";

  nodes.machine =
    { ... }:
    {
      imports = [ ./configs/minimal-node.nix ];
      console.keyMap = "dvorak";
      nixithos.branding.fastfetch.install = true;
      # a .link file, as NixOS writes it for this (unit-link applies it)
      networking.interfaces.eth1.mtu = 1400;
      # alice may set the transient host name, as polkit lets dhcpcd
      s6.hostname.allowedUsers = [ "alice" ];
      users.users.alice.isNormalUser = true;
      users.users.bob.isNormalUser = true;
    };

  testScript = ''
    machine.start()
    machine.wait_for_unit("multi-user.target")

    with subtest("init is s6"):
        machine.succeed("grep -q s6-svscan /proc/1/cmdline")
        machine.fail("pgrep -x systemd")
        # the boot transaction is over and the steady database is live
        machine.succeed("readlink /run/s6-rc/compiled | grep -q '/compiled$'")
        machine.succeed("test ! -e /run/units/.booting")

    with subtest("nothing failed"):
        print(machine.succeed("systemctl list-units --all --no-legend"))
        failed = machine.succeed("systemctl list-units --failed --no-legend").strip()
        assert failed == "", f"failed units:\n{failed}"
        machine.succeed("systemctl is-system-running")

    with subtest("early boot did its job"):
        machine.succeed("test -L /var/run && test -d /tmp && test -d /run/lock")
        machine.succeed("test -S /run/udev/control")
        machine.succeed("test -e /dev/disk/by-id || test -e /dev/disk/by-path")
        machine.succeed("test -x /run/wrappers/bin/su")
        machine.succeed("test -s /etc/machine-id")
        machine.succeed("test \"$(cat /proc/sys/kernel/hostname)\" = machine")
        machine.succeed("ip -br link show lo | grep -q UP && mountpoint -q /dev/mqueue")
        machine.succeed("test \"$(ulimit -Hn)\" = 524288")
        machine.succeed("systemctl is-active dbus.service dbus.socket && test -S /run/dbus/system_bus_socket")
        machine.succeed("ip -4 addr show dev eth1 | grep -q 192.168.1.")
        machine.succeed("mountpoint -q /sys/fs/cgroup && test -d /sys/fs/cgroup/units/dbus")

    with subtest("NixithOS, and its mark in fastfetch"):
        machine.succeed("grep -qx 'NAME=NixithOS' /etc/os-release")
        machine.succeed("grep -qx 'ID_LIKE=nixos' /etc/os-release")
        out = machine.succeed("fastfetch --pipe 2>&1")
        print(out)
        assert "OS: NixithOS" in out, out
        assert "___|___" in out and "------<" in out, out

    with subtest("link settings and the host name agent"):
        machine.succeed("test -s /etc/systemd/network/40-eth1.link")
        machine.wait_until_succeeds("ip link show eth1 | grep -q 'mtu 1400'", timeout=30)
        machine.succeed("su alice -c 'hostnamectl set-hostname --transient alices-name'")
        machine.succeed("test \"$(cat /proc/sys/kernel/hostname)\" = alices-name")
        machine.fail("su bob -c 'hostnamectl set-hostname --transient bobs-name'")
        machine.succeed("hostnamectl set-hostname --transient machine")
        machine.succeed("test \"$(cat /proc/sys/kernel/hostname)\" = machine")

    with subtest("console keyboard layout"):
        machine.succeed("systemctl is-active systemd-vconsole-setup")
        # the key that is `q` on a US keyboard
        out = machine.succeed("dumpkeys | grep -E '^keycode +16 ='")
        assert "apostrophe" in out, out

    with subtest("logging"):
        machine.succeed("logger -t boottest hello-from-syslog")
        machine.wait_until_succeeds("grep -q hello-from-syslog /var/log/s6/syslogd/current")
        machine.succeed("test -s /var/log/s6/klogd/current")
        machine.succeed("journalctl -u systemd-journald -n 5 | grep -q hello-from-syslog")

    with subtest("services can be driven"):
        machine.succeed("test -S /nix/var/nix/daemon-socket/socket")
        # socket activation: the daemon starts when a client first comes
        machine.fail("systemctl is-active nix-daemon.service")
        machine.succeed("su -s /bin/sh nobody -c 'nix-store -q --hash /run/current-system'")
        machine.wait_until_succeeds("systemctl is-active nix-daemon.service")
        pid = machine.succeed("systemctl show -p MainPID --value nix-daemon").strip()
        machine.succeed("systemctl restart nix-daemon")
        machine.succeed("systemctl is-active nix-daemon")
        newpid = machine.succeed("systemctl show -p MainPID --value nix-daemon").strip()
        assert pid != newpid and newpid not in ("", "0"), f"nix-daemon was not restarted ({pid} -> {newpid})"
        machine.succeed("systemctl stop nix-daemon")
        machine.fail("systemctl is-active nix-daemon")
        machine.succeed("systemctl start nix-daemon && systemctl is-active nix-daemon")
        # the socket outlives the service
        machine.succeed("su -s /bin/sh nobody -c 'nix-store --version' && test -S /nix/var/nix/daemon-socket/socket")

    with subtest("shutdown"):
        machine.shutdown()
  '';
}
