# The minimal system, runnable in QEMU:  nix-build -A configs.vm.vm && ./result/bin/run-six-vm
{ lib, modulesPath, ... }:

{
  imports = [
    (modulesPath + "/profiles/minimal.nix")
    (modulesPath + "/virtualisation/qemu-vm.nix")
  ];

  networking.hostName = "six";
  users.users.root.initialPassword = "root";

  virtualisation = {
    graphics = false;
    memorySize = 1024;
    cores = 2;
    diskImage = null;
  };

  system.stateVersion = "26.05";
}
