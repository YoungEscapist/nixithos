# Exercise the installer's actual disk preparation on a disposable VM disk.
# Stop at its configuration boundary; the full installation is a separate VM run.
{ pkgs, lib, ... }:
let
  diskStage = pkgs.writeShellScript "installer-disk-stage" (
    "export PATH=" + lib.makeBinPath [ pkgs.coreutils pkgs.util-linux pkgs.parted
      pkgs.dosfstools pkgs.e2fsprogs pkgs.btrfs-progs pkgs.cryptsetup pkgs.gnugrep ] + ":$PATH\n"
    + builtins.head (lib.splitString "# --- 2. the configuration" (builtins.readFile ../pkgs/nixith-installer/install.sh))
  );
in {
  name = "installer-disk";
  nodes.machine = { pkgs, ... }: {
    imports = [ ./configs/minimal-node.nix ];
    virtualisation.emptyDiskImages = [ 2048 ];
    virtualisation.memorySize = 2048;
    boot.kernelModules = [ "dm_crypt" ];
    environment.systemPackages = [ pkgs.cryptsetup pkgs.btrfs-progs ];
  };
  testScript = ''
    machine.start()
    machine.wait_for_unit("multi-user.target")
    machine.succeed("mkdir -p /mnt; head -c 1048576 /dev/vdb | sha256sum > /run/disk-before")
    env = "NI_MODE=erase NI_DISK=/dev/vdb NI_FIRMWARE=efi "
    machine.fail(env + "NI_ENCRYPT=1 NI_LUKS_FD=3 ${diskStage} 3</dev/null")
    machine.succeed("head -c 1048576 /dev/vdb | sha256sum | cmp /run/disk-before -")
    for fs in ("ext4", "btrfs"):
        for encrypted in (0, 1):
            with subtest(f"{fs}, encrypted={encrypted}"):
                command = env + f"NI_FS={fs} NI_ENCRYPT={encrypted} NI_LUKS_FD=3 ${diskStage} 3< <(printf '%s\\n' test-disk-only)"
                machine.succeed(command)
                machine.succeed(f"test $(findmnt -n -o FSTYPE /mnt) = {fs}; mountpoint /mnt/boot")
                if fs == "btrfs":
                    for mount, subvol in (("", "@"), ("/home", "@home"), ("/nix", "@nix"), ("/var/log", "@log"), ("/.snapshots", "@snapshots")):
                        machine.succeed(f"findmnt -n -o FSROOT /mnt{mount} | grep -qx /{subvol}")
                machine.succeed("echo kept > /mnt/protected")
                if encrypted:
                    machine.succeed("cryptsetup isLuks /dev/vdb2")
                    machine.fail(command)
                    machine.succeed("grep -qx kept /mnt/protected")
                else:
                    machine.fail("cryptsetup isLuks /dev/vdb2")
                machine.succeed("umount -R /mnt")
                if encrypted:
                    machine.succeed("cryptsetup close cryptroot")
    machine.shutdown()
  '';
}
