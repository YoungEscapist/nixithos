# Real btrfs subvolumes: preservation, retention, locking and the switch hook.
{
  name = "snapshots";
  nodes.machine = { pkgs, lib, ... }: {
    imports = [ ./configs/minimal-node.nix ];
    system.switch.enable = true;
    boot.loader.grub.enable = lib.mkForce false;
    virtualisation.emptyDiskImages = [ 512 ];
    environment.systemPackages = [ pkgs.btrfs-progs ];
    nixithos.snapshots = {
      enable = true;
      directory = "/data/snapshots";
      paths = [ "/data/root" "/data/home" ];
      keep = 2;
    };
  };
  testScript = ''
    machine.start()
    machine.wait_for_unit("multi-user.target")
    machine.succeed("mkfs.btrfs -f /dev/vdb; mkdir /data; mount /dev/vdb /data")
    machine.succeed("btrfs subvolume create /data/root; btrfs subvolume create /data/home; mkdir /data/snapshots")
    machine.succeed("echo before > /data/root/marker; echo personal > /data/home/marker; nixith snapshots create")
    machine.succeed("echo after > /data/root/marker; grep -qx before /data/snapshots/1/data-root/marker")
    machine.succeed("grep -qx personal /data/snapshots/1/data-home/marker; btrfs property get /data/snapshots/1/data-root ro | grep -qx ro=true")
    machine.fail("touch /data/snapshots/1/data-root/forbidden")
    machine.succeed("nixith snapshots create; nixith snapshots create; test ! -e /data/snapshots/1; test -f /data/snapshots/3/info")
    machine.succeed("nixith snapshots create & nixith snapshots create & wait")
    machine.succeed("test -f /data/snapshots/4/info; test -f /data/snapshots/5/info; test ! -e /data/snapshots/3")
    machine.fail("NIXITH_SNAPSHOT_KEEP=0 nixith snapshots prune")
    machine.succeed("ln -s /data /data/snapshots/999")
    machine.fail("nixith snapshots delete 999")
    machine.succeed("rm /data/snapshots/999; nixith snapshots delete 4; test ! -e /data/snapshots/4")
    machine.succeed("/run/current-system/bin/switch-to-configuration switch >&2")
    machine.succeed("grep -qx action=switch /data/snapshots/6/info; nixith snapshots list | grep data-root,data-home")
    machine.shutdown()
  '';
}
