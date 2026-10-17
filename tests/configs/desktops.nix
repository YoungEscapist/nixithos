# Every desktop at once, in QEMU with a screen (std VGA, software rendering),
# for looking at them by hand: ly on tty1, user "yarik", password "yarik".
#
#   nix-build -A configs.desktops.vm && ./result/bin/run-desktops-vm
{ modulesPath, ... }:

{
  imports = [ (modulesPath + "/virtualisation/qemu-vm.nix") ];

  networking.hostName = "desktops";
  users.users.yarik = {
    isNormalUser = true;
    initialPassword = "yarik";
    extraGroups = [
      "wheel"
      "video"
      "audio"
    ];
  };
  users.users.root.initialPassword = "root";

  nixithos.desktop = {
    dwl.enable = true;
    parallax.enable = true;
    gnome.enable = true;
    plasma.enable = true;
    hyprland.enable = true;
    niri.enable = true;
  };

  virtualisation = {
    memorySize = 4096;
    cores = 4;
    diskImage = null;
    qemu.options = [ "-vga std" ];
  };

  system.stateVersion = "26.05";
}
