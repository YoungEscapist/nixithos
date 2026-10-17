# NixithOS: the name this system goes by, and its mark.
#
# The name is NixOS's own setting (system.nixos.distroName/distroId), so it is
# what /etc/os-release, the boot menu, the greeting of the consoles and every
# tool that reads those say; ID_LIKE stays "nixos".  The mark is
# ../branding/nixithos.png, drawn in characters in ../branding/logo.txt, and
# that is what fastfetch shows: its configuration for the whole system names
# the drawing (with colour markers, ../branding/logo-fastfetch.txt) as the
# logo.  A user's own ~/.config/fastfetch/config.jsonc still comes first.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.nixithos.branding;

  # The mark as pictures: an icon by the name os-release gives (LOGO=nixithos),
  # and the boot menu backgrounds of the ISO (../images/iso.nix).
  artwork =
    pkgs.runCommand "nixithos-artwork"
      {
        nativeBuildInputs = [ pkgs.buildPackages.imagemagick ];
        font = "${pkgs.dejavu_fonts}/share/fonts/truetype/DejaVuSans.ttf";
      }
      ''
        # the mark alone, square, out of the 1536x1024 picture
        # (the picture's black is not quite black: compression noise, which a
        # dimmed copy behind GRUB's menu showed in colour; levelled away)
        magick ${../branding/nixithos.png} -crop 680x680+428+154 +repage \
          -colorspace Gray -level 35%,75% -type Grayscale logo.png
        for size in 16 24 32 48 64 128 256 512; do
          mkdir -p $out/share/icons/hicolor/''${size}x''${size}/apps
          magick logo.png -resize ''${size}x''${size} $out/share/icons/hicolor/''${size}x''${size}/apps/nixithos.png
        done
        mkdir -p $out/share/pixmaps $out/share/nixithos
        cp $out/share/icons/hicolor/256x256/apps/nixithos.png $out/share/pixmaps/nixithos.png
        # BIOS boot menu (syslinux, 800x600): the mark and the name above the menu
        magick -size 800x600 xc:black \( logo.png -resize 230x230 \) -gravity north -geometry +0+28 -composite \
          -font "$font" -pointsize 30 -fill white -gravity north -annotate +0+268 NixithOS \
          -type TrueColor -define png:color-type=2 $out/share/nixithos/splash-bios.png
        # UEFI boot menu (GRUB): the mark dimmed behind the menu
        magick -size 1920x1080 xc:black \( logo.png -resize 760x760 -evaluate multiply 0.35 \) -gravity center -composite \
          -font "$font" -pointsize 44 -fill '#9a9a9a' -gravity south -annotate +0+70 NixithOS \
          -type TrueColor -define png:color-type=2 $out/share/nixithos/splash-efi.png
      '';

  fastfetchConfig = {
    "$schema" = "https://github.com/fastfetch-cli/fastfetch/raw/dev/doc/json_schema.json";
    logo = {
      type = "file";
      source = "/etc/nixithos/logo-fastfetch.txt";
      # the lines of the mark, and its axes in a dimmer colour
      color = {
        "1" = "white";
        "2" = "bright_black";
      };
      padding = {
        top = 1;
        right = 3;
      };
    };
    display.color.keys = "white";
    # (a configuration file replaces fastfetch's list of modules, so this is
    # that list as fastfetch has it)
    modules = [
      "title"
      "separator"
      "os"
      "host"
      "kernel"
      "uptime"
      "packages"
      "shell"
      "display"
      "de"
      "wm"
      "wmtheme"
      "theme"
      "icons"
      "font"
      "cursor"
      "terminal"
      "terminalfont"
      "cpu"
      "gpu"
      "memory"
      "swap"
      "disk"
      "localip"
      "battery"
      "poweradapter"
      "locale"
      "break"
      "colors"
    ];
  };
in

{
  options.nixithos.branding = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether the system calls itself NixithOS (in /etc/os-release and
        everything that reads it) and fastfetch shows its mark.  Off, it is
        NixOS by name.
      '';
    };

    artwork = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      description = ''
        The mark as pictures: the `nixithos` icon (hicolor, pixmaps) and the
        boot menu backgrounds of the ISO (share/nixithos/splash-*.png).
      '';
    };

    fastfetch.install = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether to install fastfetch (its build without the optional
        dependencies).  Its configuration for the system is there either
        way, for a fastfetch installed by other means.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    system.nixos = {
      distroName = lib.mkDefault "NixithOS";
      distroId = lib.mkDefault "nixithos";
      vendorName = lib.mkDefault "NixithOS";
      vendorId = lib.mkDefault "nixithos";
      extraOSReleaseArgs = {
        LOGO = lib.mkDefault "nixithos";
        ANSI_COLOR = lib.mkDefault "1;37";
        # (the name a machine has when it was given none; dhcpcd only names
        # a machine whose name is this, see below)
        DEFAULT_HOSTNAME = lib.mkDefault "nixith";
      };
    };

    # the name of a machine nobody named
    networking.hostName = lib.mkOverride 1400 "nixith";

    # A machine without a name (networking.hostName = "") takes the one the
    # DHCP server gives it, but dhcpcd only renames a machine named
    # "localhost" or its compiled-in default, which is "nixos" in nixpkgs.
    nixpkgs.overlays = lib.mkIf (config.networking.hostName == "" && config.networking.dhcpcd.enable) [
      (final: prev: {
        dhcpcd = prev.dhcpcd.overrideAttrs (old: {
          configureFlags = map (
            f: if f == "--with-default-hostname=nixos" then "--with-default-hostname=nixith" else f
          ) old.configureFlags;
        });
      })
    ];

    environment.etc = {
      "nixithos/logo.txt".source = ../branding/logo.txt;
      "nixithos/logo-fastfetch.txt".source = ../branding/logo-fastfetch.txt;
      "nixithos/nixithos.png".source = ../branding/nixithos.png;
      "xdg/fastfetch/config.jsonc".text = builtins.toJSON fastfetchConfig;
    };

    environment.systemPackages = [ artwork ] ++ lib.optional cfg.fastfetch.install pkgs.fastfetch.minimal;
    nixithos.branding.artwork = artwork;
    # (so that the icon os-release names is found without a desktop's icon
    # themes as well: <data dir>/pixmaps/nixithos.png)
    environment.pathsToLink = [ "/share/pixmaps" ];
  };
}
