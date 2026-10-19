# The desktops NixithOS offers besides its own dwl (./dwl.nix): Parallax,
# GNOME, KDE Plasma, Hyprland and niri.
#
#   nixithos.desktop.parallax.enable = true;
#   nixithos.desktop.gnome.enable = true;
#   nixithos.desktop.plasma.enable = true;
#   nixithos.desktop.hyprland.enable = true;
#   nixithos.desktop.niri.enable = true;
#
# Each one is nixpkgs' own module for it (services.desktopManager.gnome,
# programs.niri, ...) plus what a session wants around it: sound through
# PipeWire, fonts, the programs its default configuration calls.  One is
# logged into through a display manager on the console, which needs nothing
# of systemd (GDM and SDDM are not used): ly, or greetd with tuigreet; each
# shows every session that is installed, so with several desktops there is a
# choice among them at the login.  Or through none: the console's login, and
# the session started by hand (dwl's starts by itself on tty1).
#
#   nixithos.desktop.displayManager = "ly";   # or "greetd", "none"
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.nixithos.desktop;
  dmcfg = config.services.displayManager;

  # The display manager reads these once, when it starts, and a switch does
  # not restart it (that would end the session running under it): with the
  # store path of the program in Exec=, every login after a switch still ran
  # the compositor of the generation the display manager started in. So a
  # program that is the same one in the system's path is run from there,
  # /run/current-system/sw/bin: the generation of the moment of the login.
  waylandSessions = pkgs.runCommand "wayland-sessions" { preferLocalBuild = true; } ''
    mkdir -p $out/share/wayland-sessions
    for f in ${config.services.displayManager.sessionData.desktops}/share/wayland-sessions/*.desktop; do
      grep -qE '^Exec=.*uwsm' "$f" && continue
      d=$out/share/wayland-sessions/$(basename "$f")
      cp "$f" "$d"
      chmod u+w "$d"
      for key in Exec TryExec; do
        prog=$(sed -n "s/^$key=\([^ ]*\).*/\1/p" "$d" | head -n1)
        case $prog in /nix/store/*/bin/*) ;; *) continue ;; esac
        name=''${prog##*/}
        if [ "$(readlink -f ${config.system.path}/bin/$name)" = "$(readlink -f "$prog")" ]; then
          sed -i "s|^$key=$prog|$key=/run/current-system/sw/bin/$name|" "$d"
        fi
      done
    done
  '';

  plx-wall = pkgs.callPackage ../../pkgs/plx-wall { };

  # what the session runs alongside Parallax (../../pkgs/parallax/autostart.sh)
  parallaxAutostart = pkgs.writeShellApplication {
    name = "parallax-autostart";
    runtimeInputs = with pkgs; [
      coreutils
      findutils
      gnugrep
      gnused
      dbus
      wl-clipboard
      cliphist
      mako
      plx-wall
    ];
    # (POSIX sh, as it is in the repository; not bash's strict mode)
    bashOptions = [ ];
    text = builtins.readFile ../../pkgs/parallax/autostart.sh;
  };

  parallax = pkgs.callPackage ../../pkgs/parallax { autostart = lib.getExe parallaxAutostart; };

  # Its ScreenCast backend lives inside the compositor (src/portal.rs). The
  # compositor writes this file into ~/.local/share itself, but the portal of
  # nixpkgs reads backends only from NIX_XDG_DESKTOP_PORTAL_DIR, and without
  # it ScreenCast is not on the bus at all (black screen in Vesktop and OBS).
  parallaxPortal = pkgs.writeTextDir "share/xdg-desktop-portal/portals/parallax.portal" ''
    [portal]
    DBusName=org.freedesktop.impl.portal.desktop.parallax
    Interfaces=org.freedesktop.impl.portal.ScreenCast;
    UseIn=parallax;
  '';

  # Parallax's launcher (Super+S in its configuration): rofi with the
  # applications, a second press closing it
  plx-launcher = pkgs.writeShellScriptBin "plx-launcher" ''
    if ${pkgs.procps}/bin/pkill -x rofi; then exit 0; fi
    [ $# -eq 0 ] && set -- -show drun
    exec ${lib.getExe pkgs.rofi} "$@"
  '';

  enabled = lib.filter (name: cfg.${name}.enable) [
    "parallax"
    "gnome"
    "plasma"
    "hyprland"
    "niri"
  ];

  # the session each one adds (share/wayland-sessions/<name>.desktop)
  sessionOf = {
    parallax = "parallax";
    gnome = "gnome";
    plasma = "plasma";
    hyprland = "hyprland";
    niri = "niri";
  };

  enableOption =
    what:
    lib.mkEnableOption what
    // {
      description = "Whether to enable ${what}, logged into through ly.";
    };
in
{
  options.nixithos.desktop = {
    parallax.enable = enableOption "Parallax (a Wayland compositor with an infinite canvas)";
    parallax.builtPackages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      readOnly = true;
      internal = true;
      default = [
        parallax
        plx-wall
        plx-launcher
      ];
      description = ''
        What of Parallax's is built here rather than taken from the NixOS
        binary cache: the installation image carries it, so that installing
        Parallax is not compiling it.
      '';
    };
    gnome.enable = enableOption "GNOME";
    plasma.enable = enableOption "KDE Plasma 6";
    hyprland.enable = enableOption "Hyprland";
    niri.enable = enableOption "niri (a scrollable-tiling Wayland compositor)";

    displayManager = lib.mkOption {
      type = lib.types.enum [
        "ly"
        "greetd"
        "none"
      ];
      default = if enabled != [ ] then "ly" else "none";
      defaultText = lib.literalMD ''"ly" if one of these desktops is enabled, "none" otherwise'';
      description = ''
        What to log in through, on tty1: ly, or greetd with tuigreet.  Either
        lists every installed session (dwl's too, if that is enabled: then it
        no longer starts by itself on tty1).  With "none", the console's
        login (services.displayManager.autoLogin becomes the console's
        automatic login).
      '';
    };
  };

  config = lib.mkMerge [
    (lib.mkIf (enabled != [ ]) {
      hardware.graphics.enable = true;
      fonts.enableDefaultPackages = true;
      security.polkit.enable = true;
      security.rtkit.enable = true;
      services.pipewire = {
        enable = true;
        alsa.enable = true;
        pulse.enable = true;
      };
      services.libinput.enable = true;
      # (the first one enabled, in the order above, unless said otherwise)
      # (above the mkDefault of plasma6.nix, below a setting of ones own)
      services.displayManager.defaultSession = lib.mkOverride 900 sessionOf.${lib.head enabled};
    })

    (lib.mkIf (cfg.displayManager != "none") {
      nixithos.desktop.dwl.autostart = lib.mkDefault false;
    })

    (lib.mkIf (cfg.displayManager == "ly") {
      services.displayManager.ly = {
        enable = true;
        settings = {
          animation = lib.mkDefault "matrix";
          bigclock = lib.mkDefault "en";
          # the sessions NixOS lists, but for those that only run under a
          # systemd user instance: hyprland-uwsm.desktop (uwsm starts the
          # compositor as a systemd unit of its own), which the Hyprland
          # package ships along with its plain session
          waylandsessions = "${waylandSessions}/share/wayland-sessions";
        };
      };
    })

    (lib.mkIf (cfg.displayManager == "greetd") {
      services.greetd = {
        enable = true;
        settings.default_session.command = lib.concatStringsSep " " [
          (lib.getExe pkgs.tuigreet)
          "--time --remember --remember-user-session --asterisks"
          "--sessions ${waylandSessions}/share/wayland-sessions"
        ]
        # NixithOS's greys (../theme.nix)
        + lib.optionalString config.nixithos.theme.enable (
          " "
          + lib.concatStringsSep " " [
            "--time-format '%H:%M' --greeting ${lib.escapeShellArg config.system.nixos.distroName}"
            "--window-padding 2 --container-padding 2"
            "--theme 'border=darkgray;text=gray;prompt=white;time=darkgray;action=darkgray;button=white;container=black;input=white;greet=white;title=white'"
          ]
        );
        # the automatic login: the first session greetd starts, that of the
        # default desktop, run as its .desktop file says
        settings.initial_session = lib.mkIf dmcfg.autoLogin.enable {
          user = dmcfg.autoLogin.user;
          command = toString (
            pkgs.writeShellScript "nixithos-autologin-session" ''
              exec sh -c "$(sed -n 's/^Exec=//p' ${waylandSessions}/share/wayland-sessions/${dmcfg.sessionData.autologinSession}.desktop)"
            ''
          );
        };
      };
    })

    (lib.mkIf (cfg.displayManager == "none" && dmcfg.autoLogin.enable) {
      services.getty.autologinUser = lib.mkDefault dmcfg.autoLogin.user;
    })

    (lib.mkIf cfg.parallax.enable {
      environment.systemPackages = [
        parallax
        plx-wall
        plx-launcher
        pkgs.rofi
        # its terminal (Super+Return in its configuration), and foot
        pkgs.ghostty
        pkgs.foot
        pkgs.fuzzel
        pkgs.wl-clipboard
        pkgs.cliphist
        pkgs.mako
        pkgs.libnotify
        pkgs.grim
        pkgs.slurp
        pkgs.pavucontrol
        pkgs.brightnessctl
        # the pointer: Bibata-Modern-Ice, and Adwaita, which the compositor
        # falls back to (with neither found, the pointer is invisible); and
        # the icons of the applications in the launchers and in the bar
        pkgs.bibata-cursors
        pkgs.adwaita-icon-theme
        pkgs.hicolor-icon-theme
      ];
      # The compositor and Xwayland take the pointer's theme from
      # XCURSOR_THEME; without it they look for "default", which nothing
      # provided.  GTK under Wayland reads it from its settings instead.
      environment.sessionVariables = {
        XCURSOR_THEME = lib.mkDefault "Bibata-Modern-Ice";
        XCURSOR_SIZE = lib.mkDefault "24";
      };
      xdg.icons.fallbackCursorThemes = lib.mkDefault [ "Bibata-Modern-Ice" ];
      programs.dconf = {
        enable = true;
        profiles.user.databases = [
          {
            settings."org/gnome/desktop/interface" = {
              cursor-theme = "Bibata-Modern-Ice";
              cursor-size = lib.gvariant.mkInt32 24;
              icon-theme = "Adwaita";
              color-scheme = "prefer-dark";
            };
          }
        ];
      };
      # the wallpapers a new user starts with (../../pkgs/parallax/autostart.sh
      # reads this): out of the system's, NixithOS's mark first when its look
      # is on
      environment.pathsToLink = [ "/share/backgrounds" ];
      environment.etc."parallax/session.env".text = ''
        PLX_SYSTEM_WALLPAPERS=/run/current-system/sw/share/backgrounds
        PLX_DEFAULT_WALLPAPER=${lib.optionalString config.nixithos.theme.enable "/run/current-system/sw/share/backgrounds/nixithos/nixithos.png"}
      '';
      # its Wi-Fi menu talks to NetworkManager over the system bus
      networking.networkmanager.enable = lib.mkDefault true;
      # the backlight of the screen and of the keyboard, which the compositor
      # writes into /sys itself: brightnessctl's rules let the group video
      services.udev.packages = [ pkgs.brightnessctl ];
      # the modes of its power menu, and the charge
      services.power-profiles-daemon.enable = lib.mkDefault true;
      services.upower.enable = lib.mkDefault true;
      services.dbus.packages = [ pkgs.mako ];
      # what a new user's notifications start from (autostart.sh copies it):
      # below the bar, not over it, in the greys of the bar
      environment.etc."xdg/mako/config".text = ''
        anchor=top-right
        margin=56,16,0,0
        layer=overlay
        width=360
        padding=12
        border-size=1
        border-radius=10
        background-color=#141416e6
        text-color=#e8e8ea
        border-color=#3a3a3e
        progress-color=over #5a5a60
        font=sans 11
        default-timeout=6000

        [urgency=critical]
        border-color=#c88a8a
        default-timeout=0
      '';
      # the icons of its bar and dock, and its glyphs
      fonts.packages = [ pkgs.nerd-fonts.jetbrains-mono ];
      services.displayManager.sessionPackages = [ parallax ];
      programs.xwayland.enable = true;
      xdg.portal = {
        enable = true;
        extraPortals = [
          pkgs.xdg-desktop-portal-gtk
          parallaxPortal
        ];
        config.parallax = {
          default = [ "gtk" ];
          "org.freedesktop.impl.portal.ScreenCast" = [ "parallax" ];
        };
      };
      # its Bluetooth menu (Super+Shift+B) talks to bluetoothd over the
      # system bus; Experimental for BatteryProviderManager1, through which
      # wireplumber gives the charge of headsets
      hardware.bluetooth = {
        enable = lib.mkDefault true;
        powerOnBoot = lib.mkDefault true;
        settings.General.Experimental = lib.mkDefault true;
      };
    })

    (lib.mkIf cfg.gnome.enable {
      services.desktopManager.gnome.enable = true;
      # (the session alone and its settings; the apps of GNOME are many, and
      # the image carries every desktop at once)
      services.gnome.core-apps.enable = lib.mkOverride 900 false;
      # gnome-session (49 and later) starts GNOME by asking the user's
      # service manager over D-Bus, not through systemctl: it gets that
      # D-Bus face of the s6 user manager, up before the session is
      systemd.user.services.systemd1-bus = {
        description = "org.freedesktop.systemd1 on the session bus";
        wantedBy = [ "default.target" ];
        requires = [ "dbus.service" ];
        after = [ "dbus.service" ];
        environment.SYSTEMD1_BUS_SYSTEMCTL = "${config.systemd.package}/bin/systemctl";
        serviceConfig = {
          Type = "dbus";
          BusName = "org.freedesktop.systemd1";
          ExecStart = lib.getExe (pkgs.callPackage ../../pkgs/systemd-shim/systemd1-bus.nix { });
          Restart = "on-failure";
        };
      };
      environment.systemPackages = with pkgs; [
        nautilus
        gnome-console
        gnome-text-editor
        gnome-system-monitor
      ];
    })

    (lib.mkIf cfg.plasma.enable {
      services.desktopManager.plasma6.enable = true;
      environment.plasma6.excludePackages = with pkgs.kdePackages; [
        elisa
        khelpcenter
        krdp
      ];
    })

    (lib.mkIf cfg.hyprland.enable {
      programs.hyprland.enable = true;
      # what its default configuration (hyprland.conf it writes on the first
      # start) calls: kitty, wofi, dolphin
      environment.systemPackages = with pkgs; [
        kitty
        wofi
        kdePackages.dolphin
        wl-clipboard
      ];
    })

    (lib.mkIf cfg.niri.enable {
      programs.niri.enable = true;
      # what its default configuration calls: alacritty, fuzzel, swaylock, waybar
      environment.systemPackages = with pkgs; [
        alacritty
        fuzzel
        swaylock
        waybar
        xwayland-satellite
        wl-clipboard
      ];
      # waybar's default configuration draws its icons with Font Awesome;
      # without it they are empty boxes
      fonts.packages = [ pkgs.font-awesome ];
    })
  ];
}
