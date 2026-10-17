# An installed system: the disk image is produced by nixos-install, which
# runs our switch-to-configuration to set up the boot loader, and the machine
# then boots from that disk through the boot loader, not with a kernel handed
# to it by QEMU.  GRUB (BIOS and UEFI), Limine, systemd-boot and rEFInd (all
# UEFI): the boot loaders the installer offers.  systemd-boot's installer,
# `bootctl`, is the only piece of systemd on the system.
{
  name = "bootloader";

  nodes.grub =
    { ... }:
    {
      imports = [ ./configs/minimal-node.nix ];
      # the disk image is built in a VM with QEMU from the node's packages;
      # from the binary cache that is a download, not an hour of compiling
      s6.systemdPackages = "replace";
      virtualisation.useBootLoader = true;
      boot.loader.timeout = 0;
    };

  nodes.limine =
    { ... }:
    {
      imports = [ ./configs/minimal-node.nix ];
      s6.systemdPackages = "replace";
      virtualisation.useBootLoader = true;
      virtualisation.useEFIBoot = true;
      boot.loader.efi.canTouchEfiVariables = true;
      boot.loader.limine.enable = true;
      boot.loader.limine.efiSupport = true;
      boot.loader.timeout = 0;
    };

  nodes.sdboot =
    { ... }:
    {
      imports = [ ./configs/minimal-node.nix ];
      s6.systemdPackages = "replace";
      virtualisation.useBootLoader = true;
      virtualisation.useEFIBoot = true;
      boot.loader.efi.canTouchEfiVariables = true;
      boot.loader.systemd-boot.enable = true;
      boot.loader.timeout = 0;
    };

  nodes.grubefi =
    { ... }:
    {
      imports = [ ./configs/minimal-node.nix ];
      s6.systemdPackages = "replace";
      virtualisation.useBootLoader = true;
      virtualisation.useEFIBoot = true;
      boot.loader.efi.canTouchEfiVariables = true;
      boot.loader.grub = {
        enable = true;
        device = "nodev";
        efiSupport = true;
      };
      boot.loader.timeout = 0;
    };

  nodes.refind =
    { ... }:
    {
      imports = [ ./configs/minimal-node.nix ];
      s6.systemdPackages = "replace";
      virtualisation.useBootLoader = true;
      virtualisation.useEFIBoot = true;
      boot.loader.efi.canTouchEfiVariables = true;
      boot.loader.refind.enable = true;
      boot.loader.grub.enable = false;
      # (rEFInd's 0 is "wait for a key")
      boot.loader.timeout = 1;
    };

  testScript = ''
    for machine in (grub, limine, sdboot, grubefi, refind):
        machine.start(allow_reboot=True)
        machine.wait_for_unit("multi-user.target")

        with subtest(f"{machine.name}: booted through the boot loader into s6"):
            machine.succeed("grep -q 'init=/nix/store/.*/init' /proc/cmdline")
            machine.succeed("grep -q s6-svscan /proc/1/cmdline")
            machine.succeed("test -e /run/booted-system/kernel")
            failed = machine.succeed("systemctl list-units --failed --no-legend").strip()
            assert failed == "", f"failed units:\n{failed}"

        if machine.name == "sdboot":
            with subtest("sdboot: bootctl finds the loader and the entry of this generation"):
                machine.succeed("test -e /boot/EFI/systemd/systemd-bootx64.efi")
                machine.succeed("ls /boot/loader/entries | grep -q nixos-generation-1")
                status = machine.succeed("bootctl --esp-path=/boot status 2>&1")
                assert "systemd-boot" in status, status

        with subtest(f"{machine.name}: the boot loader can be reinstalled from the running system"):
            machine.succeed("/run/current-system/bin/switch-to-configuration boot 2>&1")

        with subtest(f"{machine.name}: reboot"):
            machine.reboot()
            machine.wait_for_unit("multi-user.target")
            machine.succeed("grep -q s6-svscan /proc/1/cmdline")
            machine.shutdown()
  '';
}
