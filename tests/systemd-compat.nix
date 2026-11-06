{ pkgs, lib, ... }:
let
  python = pkgs.python3.withPackages (p: [ p.pygobject3 ]);
  probe = pkgs.writeText "systemd-compat-probe.py" (builtins.readFile ./systemd-compat.py);
in {
  name = "systemd-compat";
  nodes.machine = { pkgs, ... }: {
    imports = [ ./configs/minimal-node.nix ];
    nixithos.compat.systemd.enable = true;
    users.users.alice = { isNormalUser = true; linger = true; };
    systemd.user.services.native.serviceConfig.ExecStart = "${pkgs.coreutils}/bin/sleep infinity";
    environment.systemPackages = [ pkgs.util-linux ];
    systemd.user.services.compat-probe.serviceConfig.ExecStart = pkgs.writeShellScript "compat-probe" ''
      export GI_TYPELIB_PATH=${lib.getLib pkgs.glib}/lib/girepository-1.0
      sleep 1
      ${python}/bin/python3 ${probe} > "$XDG_RUNTIME_DIR/compat-probe.log" 2>&1
      echo $? > "$XDG_RUNTIME_DIR/compat-probe.exit"
    '';
  };
  testScript = ''
    machine.start()
    machine.wait_for_unit("multi-user.target")
    machine.wait_until_succeeds("test -S /run/user/1000/bus", timeout=60)
    machine.succeed("pgrep -u root -x s6-svscan | awk '$1 > 1 { print; exit }' > /run/user/1000/foreign.pid")
    try:
        machine.succeed("su alice -c 'XDG_RUNTIME_DIR=/run/user/1000 systemctl --user start compat-probe'")
        machine.wait_until_succeeds("test -f /run/user/1000/compat-probe.exit", timeout=180)
        print(machine.succeed("cat /run/user/1000/compat-probe.log"))
        machine.succeed("grep -qx 0 /run/user/1000/compat-probe.exit")
    except Exception:
        print(machine.execute("cat /run/user/1000/compat-probe.log; cat /home/alice/.local/state/s6/systemd1-bus/current; find /sys/fs/cgroup -name '*compat*'")[1])
        raise
    machine.succeed("loginctl disable-linger alice; user-manager stop 1000")
    machine.succeed("test ! -e /sys/fs/cgroup/user.slice/user-1000.slice/user@1000.service/nixith-compat-1000")
    machine.shutdown()
  '';
}
