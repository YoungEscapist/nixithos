# The look of NixithOS before the desktop: the boot menus (Limine, GRUB,
# rEFInd) and the logins (ly, greetd's tuigreet) in the black and white of
# its mark, out of ../pkgs/nixithos-theme.  Each is a default: a setting of
# one's own (boot.loader.grub.theme, services.displayManager.ly.settings.*,
# ...) still wins.
#
#   nixithos.theme.enable = false;   # their own looks, as nixpkgs has them
#
# systemd-boot has no look to set: its menu is text on the firmware's console.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.nixithos.theme;
  theme = pkgs.callPackage ../pkgs/nixithos-theme { };
  share = "${theme}/share/nixithos";
  # (above the mkDefaults of nixpkgs' own modules and of ./desktop, below a
  # setting of one's own)
  over = lib.mkOverride 900;
in
{
  options.nixithos.theme = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = config.nixithos.branding.enable;
      defaultText = lib.literalExpression "config.nixithos.branding.enable";
      description = ''
        Whether the boot menus and the display managers wear NixithOS's
        look: its mark, white on black.
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      default = theme;
      description = ''
        The pictures: wallpapers (share/backgrounds/nixithos), the boot menus'
        backgrounds and GRUB's theme (share/nixithos), the mark for ly.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # the wallpapers, for any desktop to pick from
    environment.systemPackages = [ theme ];
    environment.pathsToLink = [ "/share/backgrounds" ];

    boot.loader.limine.style = {
      wallpapers = over [ "${share}/limine/background.png" ];
      # (centred: stretched, a 21:9 screen would flatten the mark)
      wallpaperStyle = over "centered";
      backdrop = over "0A0A0B";
      interface = {
        branding = over config.system.nixos.distroName;
        brandingColor = over "C8C8CC";
        helpColor = over "6E6E72";
        helpColorBright = over "F0F0F2";
      };
      graphicalTerminal = {
        foreground = over "C8C8CC";
        brightForeground = over "F0F0F2";
        # black, red, green, brown, blue, magenta, cyan, grey: the greys of
        # the mark, the colours muted to match
        palette = over "0A0A0B;A86A6A;7E9A80;A8956E;7D8BA6;9A80A0;7E9EA0;A4A4AA";
        brightPalette = over "3A3A3E;C88A8A;9EBAA0;C8B58E;9DABC6;BAA0C0;9EBEC0;F0F0F2";
      };
    };

    boot.loader.grub = {
      theme = over "${share}/grub";
      splashImage = over "${share}/grub/background.png";
      backgroundColor = over "#0A0A0B";
    };

    boot.loader.refind = {
      extraConfig = lib.mkBefore ''
        # NixithOS: the mark, white on black
        banner nixithos/background.png
        banner_scale fillscreen
        selection_big nixithos/selection_big.png
        selection_small nixithos/selection_small.png
        icons_dir nixithos/icons
        hideui hints,badges
        showtools shutdown,reboot,firmware
      '';
      additionalFiles = lib.mapAttrs' (name: _: lib.nameValuePair "nixithos/${name}" "${share}/refind/${name}") {
        "background.png" = null;
        "selection_big.png" = null;
        "selection_small.png" = null;
        "icons/os_linux.png" = null;
        "icons/os_nixos.png" = null;
        "icons/os_unknown.png" = null;
      };
    };

    # ly: the mark in characters behind the box, breathing; grey on black
    # (colours are 0xSSRRGGBB, SS the style: 01 bold)
    services.displayManager.ly.settings = lib.mapAttrs (_: over) {
      animation = "dur_file";
      dur_file_path = "${share}/ly/nixithos.dur";
      dur_offset_alignment = "center";
      full_color = true;
      bigclock = "none";
      clock = "%H:%M";
      box_title = config.system.nixos.distroName;
      bg = "0x000A0A0B";
      fg = "0x00C8C8CC";
      border_fg = "0x005A5A5E";
      error_fg = "0x01C88A8A";
      error_bg = "0x000A0A0B";
      hide_version_string = true;
    };
  };
}
