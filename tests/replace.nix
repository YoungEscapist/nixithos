# The system on packages from the binary cache, with libsystemd and libudev
# swapped for elogind's and eudev's: nothing of systemd in the closure, and
# programs that were linked against it still run.
{
  name = "replace";

  nodes.machine =
    { ... }:
    {
      imports = [ ./configs/minimal-node.nix ];
      s6.systemdPackages = "replace";
    };

  testScript = ''
    machine.start()
    machine.wait_for_unit("multi-user.target")

    with subtest("no systemd in the closure"):
        closure = machine.succeed("nix-store -qR /run/current-system")
        import re
        offenders = [p for p in closure.split() if re.search(r"-systemd(-minimal|-minimal-libs)?-[0-9]", p)]
        assert not offenders, f"systemd is still there: {offenders}"
        assert "elogind-eudev-libs" in closure

    with subtest("programs run against the replacements"):
        # these were linked against libsystemd / libudev when they were built
        for prog in ("logger", "lsblk", "agetty", "dbus-daemon", "udevadm"):
            path = machine.succeed(f"readlink -f $(command -v {prog} || ls /run/current-system/sw/bin/{prog})").strip()
            print(prog, path)
        out = machine.succeed("ldd $(readlink -f $(command -v logger))")
        print(out)
        assert "elogind-eudev-libs" in out, out
        out = machine.succeed("ldd $(readlink -f $(command -v lsblk))")
        assert "libudev" in out and "eudev" in out, out
        machine.succeed("lsblk")
        machine.succeed("logger -t replace-test hello")
        machine.wait_until_succeeds("grep -q hello /var/log/s6/syslogd/current")

    with subtest("the system works"):
        machine.succeed("systemctl is-system-running")
        failed = machine.succeed("systemctl list-units --failed --no-legend").strip()
        assert failed == "", f"failed units:\n{failed}"
        machine.succeed("systemctl is-active dbus nix-daemon systemd-udevd")
        machine.succeed("busctl --system list >/dev/null 2>&1 || dbus-send --system --print-reply --dest=org.freedesktop.DBus / org.freedesktop.DBus.ListNames")
  '';
}
