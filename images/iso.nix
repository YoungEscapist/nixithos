# The installation/live image: NixOS's own minimal installation CD, with
# this tree's base modules (s6-rc in place of systemd) and NixithOS's name.
#
#   nix-build -A iso      (result/iso/nixithos-….iso)
{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}:
{
  imports = [ "${modulesPath}/installer/cd-dvd/installation-cd-minimal.nix" ];

  image.baseName = lib.mkForce "nixithos-${config.system.nixos.label}-${pkgs.stdenv.hostPlatform.system}";
  # (the label the boot menu finds the image by: at most 32 characters)
  isoImage.volumeID = lib.mkForce "nixithos-${lib.versions.majorMinor lib.version}-${pkgs.stdenv.hostPlatform.uname.processor}";

  # The image can also be booted as a file on a disk, by another boot loader:
  # its kernel and initrd with `findiso=/path/to/the.iso` on the command line
  # (stage 1 mounts each file system it finds, looking for that path).  The
  # file systems such a disk is likely to have, then:
  boot.initrd.supportedFilesystems = [
    "btrfs"
    "ext4"
    "exfat"
  ];

  # NixithOS's mark in the boot menus, in place of NixOS's artwork: the
  # backgrounds (../modules/branding.nix), no GRUB theme of NixOS's, and the
  # menu of the BIOS boot in the mark's black and white.
  isoImage.splashImage = "${config.nixithos.branding.artwork}/share/nixithos/splash-bios.png";
  isoImage.efiSplashImage = "${config.nixithos.branding.artwork}/share/nixithos/splash-efi.png";
  isoImage.grubTheme = null;
  isoImage.syslinuxTheme = lib.mkForce ''
    MENU TITLE ${config.system.nixos.distroName}
    MENU RESOLUTION 800 600
    MENU CLEAR
    MENU ROWS 6
    MENU CMDLINEROW -4
    MENU TIMEOUTROW -3
    MENU TABMSGROW  -2
    MENU HELPMSGROW -1
    MENU HELPMSGENDROW -1
    MENU MARGIN 0
    #                                FG:AARRGGBB  BG:AARRGGBB   shadow
    MENU COLOR BORDER       30;44      #00000000    #00000000   none
    MENU COLOR SCREEN       37;40      #FF000000    #00000000   none
    MENU COLOR TABMSG       37;40      #80FFFFFF    #00000000   none
    MENU COLOR TIMEOUT      1;37;40    #FFFFFFFF    #00000000   none
    MENU COLOR TIMEOUT_MSG  37;40      #FFFFFFFF    #00000000   none
    MENU COLOR CMDMARK      1;37;40    #FFFFFFFF    #00000000   none
    MENU COLOR CMDLINE      37;40      #FFFFFFFF    #00000000   none
    MENU COLOR TITLE        1;37;40    #00000000    #00000000   none
    MENU COLOR UNSEL        37;40      #FFC0C0C0    #00000000   none
    MENU COLOR SEL          7;37;40    #FF000000    #FFFFFFFF   std
  '';

  # The live user is "nixith" (NixOS's image has "nixos"), without a password,
  # logged in on the consoles.
  users.users.nixos.enable = false;
  users.users.nixith = {
    isNormalUser = true;
    extraGroups = [
      "wheel"
      "networkmanager"
      "video"
    ];
    initialHashedPassword = "";
  };
  services.getty.autologinUser = lib.mkOverride 45 "nixith";
  nix.settings.trusted-users = lib.mkForce [
    "root"
    "nixith"
  ];
  # (no configuration of the live system itself in /etc/nixith: this one is
  # built from the tree, not changed in place)
  installer.cloneConfig = false;

  services.getty.helpLine = lib.mkForce ''
    The "nixith" and "root" accounts have empty passwords.

    To log in over ssh you must set a password for either "nixith" or "root"
    with `passwd` (prefix with `sudo` for "root"), or add your public key to
    /home/nixith/.ssh/authorized_keys or /root/.ssh/authorized_keys.

    To set up a wireless connection, run `nmtui`.

    To install NixithOS: partition and mount the disk on /mnt, then
    `sudo nixith generate-config --root /mnt`, edit
    /mnt/etc/nixith/configuration.nix and `sudo nixith install`.
  '';
}
