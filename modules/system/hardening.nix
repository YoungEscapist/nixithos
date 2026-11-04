# What the units ask for in protection, and what is not given.
#
# The modules of nixpkgs lean on systemd to confine their services: sandboxes,
# system call filters, resource limits.  Most of that is done by the runtime
# (pkgs/unit-runtime, unit-sandbox, unit-seccomp, the control group of the
# unit); the rest is not, and a service that asks for it runs without it.
# That must not pass unnoticed, so the build says which units ask for what
# is not done (unitc writes the same into report.txt of the database).
#
# Done: PrivateTmp, PrivateDevices, PrivateNetwork, PrivateIPC, PrivateMounts,
# ProtectSystem, ProtectHome, ProtectKernel{Tunables,Modules,Logs}, ProtectClock,
# ProtectControlGroups, ProtectHostname, ProtectProc, ProcSubset, the path
# lists (ReadWritePaths… TemporaryFileSystem), RootDirectory, NoNewPrivileges,
# CapabilityBoundingSet, AmbientCapabilities, SystemCallFilter,
# SystemCallErrorNumber, SystemCallArchitectures, RestrictAddressFamilies,
# RestrictNamespaces, RestrictRealtime, RestrictSUIDSGID,
# MemoryDenyWriteExecute, LockPersonality, and (in the control group of a
# system service) MemoryMax, MemoryHigh, MemoryLow, MemoryMin, MemorySwapMax,
# CPUQuota, CPUWeight, TasksMax, IOWeight, AllowedCPUs, AllowedMemoryNodes.
{ config, lib, ... }:

let
  cfg = config.nixithos.hardening;

  # Asked for by systemd.exec(5) and systemd.resource-control(5), and not done.
  unapplied = [
    "PrivateUsers"
    "PrivatePIDs"
    "RemoveIPC"
    "IPAddressAllow"
    "IPAddressDeny"
    "DevicePolicy"
    "DeviceAllow"
    "SocketBindAllow"
    "SocketBindDeny"
    "RestrictNetworkInterfaces"
    "RestrictFileSystems"
    "ExecPaths"
    "NoExecPaths"
    "SystemCallLog"
    "MountFlags"
    "RootImage"
    "NetworkNamespacePath"
    "IPCNamespacePath"
    "SecureBits"
    "SELinuxContext"
    "AppArmorProfile"
    "SmackProcessLabel"
  ];

  # …and in a user's service, which has no control group of its own to limit
  userUnapplied = unapplied ++ [
    "MemoryMax"
    "MemoryHigh"
    "MemoryLow"
    "MemoryMin"
    "MemorySwapMax"
    "CPUQuota"
    "CPUWeight"
    "TasksMax"
    "IOWeight"
    "AllowedCPUs"
    "AllowedMemoryNodes"
  ];

  # A value that asks for nothing (what the default is, or what is off).
  isNoop =
    v:
    if v == null || v == false then
      true
    else if lib.isList v then
      lib.all isNoop v
    else if lib.isString v then
      lib.elem (lib.toLower (lib.trim v)) [
        ""
        "no"
        "false"
        "off"
        "0"
        "auto"
        "infinity"
        "default"
      ]
    else
      false;

  asked =
    keys: services:
    lib.filterAttrs (_: opts: opts != [ ]) (
      lib.mapAttrs (
        _: svc:
        lib.optionals (svc.enable or true) (
          lib.filter (
            k: svc.serviceConfig ? ${k} && !isNoop svc.serviceConfig.${k} && !(lib.elem k cfg.ignore)
          ) keys
        )
      ) services
    );

  system = asked unapplied config.systemd.services;
  user = asked userUnapplied config.systemd.user.services;

  lines =
    scope: set:
    lib.mapAttrsToList (n: opts: "  ${scope}${n}: ${lib.concatStringsSep ", " opts}") set;
in
{
  options.nixithos.hardening = {
    warnUnapplied = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Warn, when the system is built, about the units that ask for
        protection which the runtime does not give them (IPAddressDeny=,
        DeviceAllow=, PrivateUsers=, resource limits of a user's service,
        and the like), as one warning with the units and their settings.
        The settings of units that come from packages and not from
        `systemd.services` are not looked at here; unitc lists those in the
        `report.txt` of the unit database.
      '';
    };

    ignore = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [
        "PrivateUsers"
        "RemoveIPC"
      ];
      description = "Settings the warning leaves out.";
    };

    unapplied = lib.mkOption {
      type = lib.types.attrsOf (lib.types.listOf lib.types.str);
      readOnly = true;
      internal = true;
      default = system // lib.mapAttrs' (n: v: lib.nameValuePair "user:${n}" v) user;
      description = "The settings of units that are asked for and not done; what the warning lists.";
    };
  };

  config.warnings = lib.optional (cfg.warnUnapplied && (system != { } || user != { })) ''
    Some units ask for protection that NixithOS does not give them (they run
    without it):
    ${lib.concatStringsSep "\n" (lines "" system ++ lines "user " user)}
    Set nixithos.hardening.warnUnapplied = false to silence this, or list
    settings in nixithos.hardening.ignore.
  '';
}
