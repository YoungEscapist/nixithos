# Smallest configuration that still describes a real machine.
{ lib, modulesPath, ... }:

{
  imports = [ (modulesPath + "/profiles/minimal.nix") ];

  boot.loader.grub.enable = false;
  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
  };

  networking.hostName = "six";
  users.users.root.initialPassword = "root";

  system.stateVersion = "26.05";
}
