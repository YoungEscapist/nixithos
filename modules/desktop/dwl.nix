# NixithOS's desktop: dwl (a tiling Wayland compositor) with foot as the
# terminal and fuzzel as the launcher, sound through PipeWire, the mark as the
# wallpaper.  What the dwl image boots into, and what its installer installs.
#
#   nixithos.desktop.dwl.enable = true;
#
# The session starts on tty1 when a user logs in there; the other consoles
# stay text ones.  Keys (Super is the modifier): Super+Shift+Enter a
# terminal, Super+P the launcher, Super+J/K the next/previous window,
# Super+Shift+C close it, Super+1…9 the tags, Super+Shift+Q leave dwl.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.nixithos.desktop.dwl;

  # dwl's configuration is its config.h: the stock one, with fuzzel in place
  # of wmenu, Super in place of Alt (Alt belongs to the programs), and the
  # black of the mark.
  dwlConfig = pkgs.runCommand "dwl-config.h" { } ''
    sed \
      -e 's/"wmenu-run"/"fuzzel"/' \
      -e 's/#define MODKEY WLR_MODIFIER_ALT/#define MODKEY WLR_MODIFIER_LOGO/' \
      -e 's/rootcolor\[\] *= COLOR(0x222222ff)/rootcolor[] = COLOR(0x000000ff)/' \
      ${pkgs.dwl.src}/config.def.h > $out
    grep -q '"fuzzel"' $out && grep -q 'WLR_MODIFIER_LOGO$' $out
  '';
  dwl = pkgs.dwl.override { configH = dwlConfig; };

  # The session of programs.dwl (it tells the user's service manager that a
  # graphical session is there), with what dwl runs at its start.
  session = pkgs.writeShellScript "nixithos-dwl-session" ''
    # (in the session only: other desktops may be installed beside it)
    export XDG_CURRENT_DESKTOP=dwl
    systemctl --user import-environment DISPLAY WAYLAND_DISPLAY XDG_CURRENT_DESKTOP
    systemctl --user start dwl-session.target
    exec ${lib.getExe dwl} -s ${lib.escapeShellArg cfg.startup}
  '';
in
{
  options.nixithos.desktop.dwl = {
    enable = lib.mkEnableOption "the dwl desktop of NixithOS (dwl, foot, fuzzel, PipeWire)";

    autostart = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether logging in on tty1 starts the graphical session.  (With a
        display manager, as with the other desktops, it is off: the session
        is chosen there.)
      '';
    };

    wallpaper = lib.mkOption {
      type = lib.types.path;
      default = "${config.nixithos.branding.artwork}/share/nixithos/splash-efi.png";
      defaultText = lib.literalMD "the mark of NixithOS";
      description = "The picture behind the windows.";
    };

    startup = lib.mkOption {
      type = lib.types.str;
      default = "${lib.getExe pkgs.swaybg} -m fill -i ${cfg.wallpaper}";
      defaultText = lib.literalMD "swaybg with `wallpaper`";
      description = "The command dwl runs when it starts (`dwl -s`).";
    };
  };

  config = lib.mkIf cfg.enable {
    programs.dwl = {
      enable = true;
      package = dwl;
    };
    hardware.graphics.enable = true;
    fonts.enableDefaultPackages = true;
    fonts.packages = [ pkgs.dejavu_fonts ];

    security.rtkit.enable = true;
    services.pipewire = {
      enable = true;
      alsa.enable = true;
      pulse.enable = true;
    };

    # what a display manager runs for the dwl session of programs.dwl: the
    # same session as on tty1, with the startup command
    environment.etc."xdg/dwl-session".text = lib.mkForce ''
      #!/bin/sh
      exec ${session}
    '';

    environment.loginShellInit = lib.mkIf cfg.autostart ''
      if [ "$(tty)" = /dev/tty1 ] && [ -z "''${WAYLAND_DISPLAY-}" ]; then
        exec ${session}
      fi
    '';

    environment.etc."xdg/foot/foot.ini".text = ''
      font=DejaVu Sans Mono:size=11
      [colors-dark]
      alpha=0.92
      background=000000
      foreground=e6e6e6
    '';
    environment.etc."xdg/fuzzel/fuzzel.ini".text = ''
      [main]
      font=DejaVu Sans:size=12
      terminal=foot
      prompt="❯ "
      lines=12
      width=40
      [colors]
      background=000000ee
      text=d0d0d0ff
      match=ffffffff
      selection=ffffffff
      selection-text=000000ff
      selection-match=000000ff
      border=ffffffff
      [border]
      width=1
      radius=0
    '';

    environment.systemPackages = with pkgs; [
      foot
      fuzzel
      swaybg
      wl-clipboard
      grim
      slurp
      wlr-randr
      brightnessctl
      pamixer
      pavucontrol
    ];
  };
}
