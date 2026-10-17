# Network time: the clock is stepped to what a server says, and the system
# says it is synchronized.  The server is a few lines of Python that is an
# hour ahead.
{
  name = "timesync";

  nodes.machine =
    { pkgs, lib, ... }:
    let
      server = pkgs.writeText "sntp-server.py" ''
        import socket, struct, time

        OFFSET = 3600          # seconds ahead
        EPOCH = 2208988800

        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s.bind(("127.0.0.1", 123))
        print("listening", flush=True)

        def ts(t):
            sec = int(t) + EPOCH
            frac = int((t - int(t)) * 2**32)
            return struct.pack("!II", sec, frac)

        while True:
            data, addr = s.recvfrom(512)
            if len(data) < 48:
                continue
            now = time.time() + OFFSET
            reply = bytearray(48)
            reply[0] = (0 << 6) | (4 << 3) | 4     # LI 0, v4, server
            reply[1] = 2                           # stratum
            reply[24:32] = data[40:48]             # originate = their transmit
            reply[32:40] = ts(now)
            reply[40:48] = ts(now)
            s.sendto(bytes(reply), addr)
      '';
    in
    {
      imports = [ ./configs/minimal-node.nix ];
      # (the VM profile turns it off)
      services.timesyncd.enable = lib.mkForce true;
      services.timesyncd.servers = [ "127.0.0.1" ];
      services.timesyncd.fallbackServers = [ ];
      systemd.services.fake-sntp = {
        wantedBy = [ "multi-user.target" ];
        before = [ "systemd-timesyncd.service" ];
        serviceConfig.ExecStart = "${pkgs.python3}/bin/python3 ${server}";
      };
    };

  testScript = ''
    import time

    machine.start()
    machine.wait_for_unit("multi-user.target")

    with subtest("timesyncd runs, unprivileged but for setting the clock"):
        machine.succeed("systemctl is-active systemd-timesyncd")
        pid = machine.succeed("systemctl show -p MainPID --value systemd-timesyncd").strip()
        assert machine.succeed(f"stat -c %U /proc/{pid}").strip() == "systemd-timesync"

    with subtest("the clock follows the server"):
        machine.wait_until_succeeds("test -e /run/systemd/timesync/synchronized", timeout=120)
        ahead = int(machine.succeed("date +%s")) - int(time.time())
        assert 3500 < ahead < 3700, f"the clock is {ahead}s ahead of the host, expected about 3600"

    with subtest("timedatectl agrees"):
        assert machine.succeed("timedatectl show -p NTPSynchronized --value").strip() == "yes"
        machine.succeed("timedatectl status | grep 'System clock synchronized: yes'")

    with subtest("the time of the last synchronization is kept"):
        machine.succeed("test -e /var/lib/systemd/timesync/clock")
  '';
}
