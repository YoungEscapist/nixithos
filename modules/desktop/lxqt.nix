# A light desktop with floating windows: LXQt on labwc (a stacking Wayland
# compositor in the manner of Openbox), with its panel, menu, file manager
# and settings.  What the graphical image boots into: Calamares is a Qt
# program too, so LXQt costs the image little beyond what it already has.
#
#   nixithos.desktop.lxqt.enable = true;
#
# The session starts on tty1 when a user logs in there, as dwl's does.  It is
# LXQt's own startlxqtwayland with the compositor set to labwc; on the first
# start it copies LXQt's labwc configuration into ~/.config/labwc.  Programs
# to start with the session go to /etc/xdg/autostart (lxqt-session starts
# them).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.nixithos.desktop.lxqt;
  lxqt = pkgs.lxqt;

  # LXQt keeps its default configuration in $prefix/share/lxqt and finds it
  # through XDG_CONFIG_DIRS (what nixpkgs' X session of LXQt does as well);
  # the files under /etc/xdg below come before them and are copies of them
  # with what NixithOS changes.
  sessionConf = pkgs.runCommand "lxqt-session.conf" { } ''
    sed -e 's/^\[General\]$/[General]\ncompositor=labwc/' \
      ${lxqt.lxqt-session}/share/lxqt/session.conf > $out
    grep -q '^compositor=labwc$' $out
  '';
  pcmanfmConf = pkgs.runCommand "pcmanfm-qt-settings.conf" { } ''
    sed \
      -e 's|^Wallpaper=.*|Wallpaper=${cfg.wallpaper}|' \
      -e 's|^WallpaperMode=.*|WallpaperMode=zoom|' \
      -e 's|^IconThemeName=.*|IconThemeName=breeze-dark|' \
      ${lxqt.pcmanfm-qt}/share/pcmanfm-qt/lxqt/settings.conf > $out
    grep -q '^Wallpaper=${cfg.wallpaper}$' $out
  '';

  session = pkgs.writeShellScript "nixithos-lxqt-session" ''
    export XDG_CONFIG_DIRS="''${XDG_CONFIG_DIRS:+$XDG_CONFIG_DIRS:}/run/current-system/sw/share"
    exec ${lxqt.lxqt-wayland-session}/bin/startlxqtwayland
  '';
in
{
  options.nixithos.desktop.lxqt = {
    enable = lib.mkEnableOption "LXQt on labwc, a light desktop with floating windows";

    autostart = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether logging in on tty1 starts the graphical session.  (With a
        display manager it is off: the session is chosen there.)
      '';
    };

    wallpaper = lib.mkOption {
      type = lib.types.path;
      default = "${config.nixithos.branding.artwork}/share/nixithos/splash-efi.png";
      defaultText = lib.literalMD "the mark of NixithOS";
      description = "The picture on the desktop.";
    };
  };

  config = lib.mkIf cfg.enable {
    services.xserver.desktopManager.lxqt = {
      enable = true;
      iconThemePackage = pkgs.kdePackages.breeze-icons;
    };
    # (its screensaver is an X one, and openbox stays unused under labwc)
    environment.lxqt.excludePackages = [ pkgs.xscreensaver ];
    programs.labwc.enable = true;

    hardware.graphics.enable = true;
    fonts.enableDefaultPackages = true;

    security.rtkit.enable = true;
    services.pipewire = {
      enable = true;
      alsa.enable = true;
      pulse.enable = true;
    };

    environment.etc."xdg/lxqt/session.conf".source = sessionConf;
    environment.etc."xdg/pcmanfm-qt/lxqt/settings.conf".source = pcmanfmConf;

    environment.loginShellInit = lib.mkIf cfg.autostart ''
      if [ "$(tty)" = /dev/tty1 ] && [ -z "''${WAYLAND_DISPLAY-}" ]; then
        exec ${session}
      fi
    '';

    environment.systemPackages = with pkgs; [
      swaybg
      wl-clipboard
      grim
      slurp
      wlr-randr
    ];
  };
}
