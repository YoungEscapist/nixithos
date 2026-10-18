# The live/installation image with a graphical installer: the image of
# ./iso.nix with a light desktop, LXQt on labwc (../modules/desktop/lxqt.nix),
# started on tty1 for the live user "nixith" (no password), everyday tools,
# and Calamares made into NixithOS's installer (../pkgs/calamares-nixithos),
# which starts with the session.  The desktop of the installed system is
# chosen in the installer (dwl, Parallax, GNOME, Plasma, Hyprland, niri or
# none), with what to log in through, the shell and the boot loader; what is
# not on the image comes from the binary cache (Parallax, built here, is on
# it).
#
#   nix-build -A isoGraphical   (result/iso/nixithos-graphical-….iso)
{
  config,
  lib,
  pkgs,
  ...
}:
let
  calamares = pkgs.callPackage ../pkgs/calamares-nixithos {
    inherit (config.nixithos.branding) artwork;
  };

  # Calamares runs as root (it partitions, mounts and installs), on the
  # session's Wayland display; the live user may use sudo without a password.
  installer = pkgs.writeShellScriptBin "nixithos-installer" ''
    exec sudo --preserve-env=WAYLAND_DISPLAY,XDG_RUNTIME_DIR,XDG_DATA_DIRS,XDG_CONFIG_DIRS,QT_QPA_PLATFORM \
      env QT_QPA_PLATFORM=wayland ${lib.getExe calamares} "$@"
  '';
  installerEntry = pkgs.makeDesktopItem {
    name = "nixithos-installer";
    desktopName = "Install NixithOS";
    comment = "Install NixithOS on this computer";
    exec = "nixithos-installer";
    icon = "nixithos";
    categories = [ "System" ];
  };

  # Calamares looks up the console keymaps that go with a keyboard layout in
  # systemd's table, at /run/current-system/sw/share/systemd/kbd-model-map; a
  # table of names, nothing of systemd's running parts.
  kbdModelMap = pkgs.runCommand "kbd-model-map" { } ''
    install -Dm444 ${pkgs.systemd}/share/systemd/kbd-model-map $out/share/systemd/kbd-model-map
  '';
in
{
  imports = [ ./iso.nix ];

  image.baseName = lib.mkOverride 40 "nixithos-graphical-${config.system.nixos.label}-${pkgs.stdenv.hostPlatform.system}";
  isoImage.appendToMenuLabel = " (graphical)";

  # LXQt on tty1, where the live user is logged in by itself (./iso.nix); the
  # installer starts with the session (lxqt-session runs /etc/xdg/autostart)
  nixithos.desktop.lxqt.enable = true;
  nixithos.liveInstaller = false;
  environment.etc."xdg/autostart/nixithos-installer.desktop".source =
    "${installerEntry}/share/applications/nixithos-installer.desktop";
  nixithos.utilities.enable = true;

  # Parallax is built from this tree, not in the binary cache: it is on the
  # image, so that installing it is not compiling it
  isoImage.storeContents = [ (pkgs.callPackage ../pkgs/parallax { }) ];

  # (the minimal profile under ./iso.nix turns these off; a desktop wants them)
  fonts.fontconfig.enable = lib.mkForce true;
  xdg.icons.enable = lib.mkForce true;
  xdg.mime.enable = lib.mkForce true;

  # calamares runs pkexec as root for its steps: polkit lets root through
  security.polkit.enable = true;
  # The partitioner (KPMcore) does its work through a helper it starts over
  # the system bus (org.kde.kpmcore.helperinterface); without it there are
  # "no partitions to install on".  (What programs.partition-manager does,
  # without the KDE application.)
  services.dbus.packages = [ pkgs.kdePackages.kpmcore ];

  environment.systemPackages = [
    calamares
    installer
    installerEntry
    kbdModelMap
    pkgs.firefox
    # (its polkit actions)
    pkgs.kdePackages.kpmcore
    pkgs.gparted
    # what kpmcore runs (it looks for it in the system's profile: see
    # ../pkgs/overlay.nix)
    pkgs.util-linux
    pkgs.dosfstools
    pkgs.e2fsprogs
    pkgs.btrfs-progs
    pkgs.xfsprogs
    pkgs.f2fs-tools
    pkgs.exfatprogs
    pkgs.ntfs3g
    pkgs.lvm2
    pkgs.cryptsetup
    pkgs.mdadm
    pkgs.smartmontools
  ];

  services.getty.helpLine = lib.mkAfter ''

    LXQt and the installer are on tty1.  "Install NixithOS" in the menu
    (System) starts the installer again.
  '';
}
