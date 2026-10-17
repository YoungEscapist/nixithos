# Changing the host name for programs that may not do it themselves: the part
# of systemd-hostnamed that NixOS relies on.
#
# dhcpcd (networking.dhcpcd.setHostname, on by default) runs as its own user
# in a sandbox of its own UTS namespace, and gives the host the name the DHCP
# server sends with `hostnamectl set-hostname --transient NAME`.  Upstream
# that is a D-Bus call to hostnamed, which polkit allows for the user dhcpcd.
# Here hostnamectl asks a small root service over a socket instead; the
# kernel tells the service who is asking (SO_PEERCRED, through
# s6-ipcserver), and it lets root and the users of s6.hostname.allowedUsers
# set the transient name, which is all hostnamectl changes (the static one is
# networking.hostName).
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.s6.hostname;
  socket = "/run/hostname-agent/socket";

  dhcpSetsHostname =
    config.networking.dhcpcd.enable
    && config.networking.dhcpcd.setHostname
    && (
      config.networking.useDHCP
      || lib.any (i: i.useDHCP == true) (lib.attrValues config.networking.interfaces)
    );

  # one request per connection: "transient NAME", answered "ok" or "error: …"
  handler = pkgs.writeShellScript "hostname-request" ''
    export PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.gnugrep ]}
    answer() { printf '%s\n' "$1"; exit 0; }
    read -r -t 5 verb name || answer "error: no request"
    [[ $verb == transient ]] || answer "error: unknown request $verb"
    uid=''${IPCREMOTEEUID-}
    [[ -n $uid ]] || answer "error: who is asking?"
    if [[ $uid != 0 ]]; then
      user=$(id -nu "$uid" 2>/dev/null) || answer "error: no user $uid"
      grep -qxF -- "$user" /etc/units/hostname-users 2>/dev/null ||
        answer "error: $user may not change the host name"
    fi
    # what hostnamed takes for a host name
    [[ ''${#name} -le 64 && $name =~ ^[A-Za-z0-9_-]([A-Za-z0-9_.-]*[A-Za-z0-9_-])?$ ]] ||
      answer "error: not a valid host name: $name"
    { printf '%s' "$name" > /proc/sys/kernel/hostname; } 2>/dev/null ||
      answer "error: cannot set the host name"
    answer ok
  '';
in

{
  options.s6.hostname.allowedUsers = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = lib.optional dhcpSetsHostname "dhcpcd";
    defaultText = lib.literalMD ''`[ "dhcpcd" ]` where dhcpcd runs and sets the host name, `[ ]` otherwise'';
    example = [ "networkmanager" ];
    description = ''
      Users other than root that may set the transient host name with
      {command}`hostnamectl set-hostname --transient` (what polkit allows
      them under systemd-hostnamed).  If there are any, a small service
      changes the host name on their behalf.
    '';
  };

  config = lib.mkIf (cfg.allowedUsers != [ ]) {
    environment.etc."units/hostname-users".text = lib.concatLines cfg.allowedUsers;

    systemd.services.hostname-agent = {
      description = "Host name changes on behalf of other users";
      wantedBy = [ "network.target" ];
      before = [ "network-pre.target" ];
      unitConfig = {
        DefaultDependencies = false;
        X-S6-Name = "hostname-agent";
      };
      serviceConfig = {
        ExecStart = "${pkgs.s6}/bin/s6-ipcserver -- ${socket} ${handler}";
        RuntimeDirectory = "hostname-agent";
        RuntimeDirectoryMode = "0755";
        Restart = "always";
      };
    };

    systemd.services.dhcpcd = lib.mkIf dhcpSetsHostname {
      wants = [ "hostname-agent.service" ];
      after = [ "hostname-agent.service" ];
    };
  };
}
