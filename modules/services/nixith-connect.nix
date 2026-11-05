# Optional integration for a separately supplied Nixith Connect package.
#
#   services.nixith-connect = {
#     enable = true;
#     package = pkgs.callPackage /path/to/nixith-connect { };
#     loginServer = "https://headscale.example.org";
#   };
#
# The daemon is the user's, not the system's: it lives in the graphical
# session (it needs Wayland, the session bus, the sound), started there by
# parallax-autostart (../../pkgs/parallax/autostart.sh) when
# /etc/nixith-connect/autostart exists, and by XDG autostart elsewhere.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.nixith-connect;
in
{
  options.services.nixith-connect = {
    enable = lib.mkEnableOption "Nixith Connect, the device link";

    package = lib.mkOption {
      type = lib.types.package;
      description = "The package with nixconnect.";
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Open 1714-1764 TCP/UDP: announcements, the link, files, the screen.";
    };

    tailscale = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Run tailscaled, the client of the Headscale network.";
    };

    loginServer = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "https://headscale.example.org";
      description = "One's own Headscale, for `tailscale up --login-server`.";
    };

    user = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "alice";
      description = ''
        The user who may join and leave the network (`nixconnect net join`)
        without sudo: tailscaled's operator.
      '';
    };

    authKeyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = "/etc/nixith-connect/authkey";
      description = ''
        A pre-authorised key of the Headscale (headscale preauthkeys create):
        with it the machine joins the network by itself at boot.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ cfg.package ];

    networking.firewall = lib.mkIf cfg.openFirewall {
      allowedTCPPortRanges = [
        {
          from = 1714;
          to = 1764;
        }
      ];
      allowedUDPPortRanges = [
        {
          from = 1714;
          to = 1764;
        }
      ];
    };

    services.tailscale = lib.mkIf cfg.tailscale {
      enable = true;
      extraUpFlags = lib.optional (cfg.loginServer != null) "--login-server=${cfg.loginServer}" ++ [
        "--accept-dns=false"
      ];
      extraSetFlags = lib.optional (cfg.user != null) "--operator=${cfg.user}";
      authKeyFile = lib.mkIf (cfg.authKeyFile != null) cfg.authKeyFile;
    };

    # Bypass rules of VPN clients (minewire-tun) send 100.64.0.0/10 to the
    # main table: the provider's carrier-grade NAT uses the same range. That
    # sends the replies to Headscale peers out through Wi-Fi instead of
    # tailscale0. Table 52 holds only the peers' own addresses, so looking it
    # up first changes nothing for the provider's: they fall through to the
    # next rule.
    systemd.services.nixith-tailnet-route = lib.mkIf cfg.tailscale {
      description = "Headscale peers through tailscale0, ahead of VPN bypass rules";
      wantedBy = [ "multi-user.target" ];
      after = [ "tailscaled.service" ];
      path = [ pkgs.iproute2 ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        ip rule del to 100.64.0.0/10 lookup 52 priority 480 2>/dev/null || true
        ip rule add to 100.64.0.0/10 lookup 52 priority 480
        ip -6 rule del to fd7a:115c:a1e0::/48 lookup 52 priority 480 2>/dev/null || true
        ip -6 rule add to fd7a:115c:a1e0::/48 lookup 52 priority 480 || true
      '';
    };

    environment.etc."nixith-connect/autostart".text = "";
    environment.etc."xdg/autostart/nixith-connect-daemon.desktop".source =
      "${cfg.package}/etc/xdg/autostart/nixith-connect-daemon.desktop";
  };
}
