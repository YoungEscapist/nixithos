# runit as init (nixithos.init = "runit").
#
#   PID 1     runit, which runs three programs in turn (/etc/runit/1, 2, 3):
#   stage 1   sets the runtime directory up: the database in use
#             (/run/units/.db, as with dinit), the directory runsvdir looks
#             in, the service of unit-rc
#   stage 2   runsvdir over /run/units/rsv.  A runsv for every process of the
#             database sits in it, idle (a `down` file), and one for unit-rc,
#             which knows what starts after what (../../pkgs/unit-tools/unit-rc.c):
#             it reads the descriptions unitc writes (runit/ in the database),
#             runs the oneshots, and has runsv start the processes - under
#             unit-supervise, which keeps the contract of s6-supervise
#             (readiness, finish, the status in /run/units/.sv/ATOM)
#   stage 3   `systemctl poweroff` and friends stop the units in the reverse
#             order of their start, then ask runit to end stage 2 (runit-init
#             0 or 6, as ever); stage 3 kills what is left, unmounts and
#             leaves the root file system read-only
#
# The options of ../s6 that are not about s6-linux-init or s6-rc apply here
# too: s6.init.path, .environment, .limits and .finalCommands, s6.logging,
# s6.rc.services (native services: unitc writes descriptions for them).
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.runit;
  initCfg = config.s6.init;
  db = config.system.build.s6Database;
  sh = pkgs.runtimeShell;
  unitTools = pkgs.nixithos.unitTools;

  limits = import ../init-limits.nix { inherit lib; } initCfg.limits;

  binPath = lib.makeBinPath [
    pkgs.runit
    unitTools
    pkgs.coreutils
    pkgs.util-linux
  ];

  # what the services of the machine start with: the environment of
  # runsvdir (dinit's -e, or s6-linux-init's)
  environment = [
    "PATH=${pkgs.runit}/bin:${unitTools}/bin:${initCfg.path}"
  ]
  ++ lib.mapAttrsToList (n: v: "${n}=${v}") initCfg.environment;

  init = pkgs.writeScriptBin "init" ''
    #!${sh}
    # Stage 2 of NixOS is done; runit takes over as PID 1.
    PATH=${lib.makeBinPath [ pkgs.coreutils ]}

    # hard limits of PID 1, inherited by everything (s6.init.limits)
    ${limits}

    # What runit looks at when it is told to stop, and to reboot rather than
    # power off (runit-init 0 or 6): files that change, so not of /etc/static.
    mkdir -p /etc/runit
    for f in stopit reboot; do
      rm -f /etc/runit/$f
      : > /etc/runit/$f
      chmod 0 /etc/runit/$f
    done

    exec ${pkgs.runit}/bin/runit
  '';

  stage1 = pkgs.writeScript "runit-1" ''
    #!${sh}
    PATH=${binPath}

    mkdir -p /run/units /run/uncaught-logs
    # The unit database of this configuration: unit-rc reads the services from
    # it, and the services find their unit data in it.  A switch points it at
    # another one (switch-to-configuration).
    ln -sfn ${db} /run/units/.db
    # (kept from the garbage collector while it is in use, also when it is no
    # longer the one of the current system)
    ln -sfn ${db} /nix/var/nix/gcroots/units-live 2>/dev/null
    # Tells `systemctl` that the boot is still under way; the `boot` service
    # takes it away at the end (unit-runtime booted).
    : > /run/units/.booting

    # The directory runsvdir looks in: a runsv for every process of the
    # database (unit-rc prepare), and the service of unit-rc itself.
    rm -rf /run/units/rsv
    mkdir -p /run/units/rsv/unit-rc
    cat > /run/units/rsv/unit-rc/run <<'EOF'
    #!${sh}
    exec >> /run/uncaught-logs/unit-rc 2>&1
    ${lib.optionalString cfg.verbose "export UNIT_RC_DEBUG=1"}
    exec unit-rc daemon -b ${sh} -t boot
    EOF
    chmod 0755 /run/units/rsv/unit-rc/run
    unit-rc prepare -b ${sh} >> /run/uncaught-logs/unit-rc 2>&1
    exit 0
  '';

  stage2 = pkgs.writeScript "runit-2" ''
    #!${sh}
    PATH=${binPath}
    exec < /dev/null >> /run/uncaught-logs/services 2>&1
    exec env -i ${lib.concatMapStringsSep " " lib.escapeShellArg environment} \
      runsvdir -P /run/units/rsv
  '';

  stage3 = pkgs.writeScript "runit-3" ''
    #!${sh}
    PATH=${binPath}
    trap "" TERM HUP INT

    # The units were stopped in order by whoever asked (systemctl); what is
    # left is asked to go, then runit kills it.
    kill -TERM -1 2>/dev/null
    sleep 1

    ${initCfg.finalCommands}

    sync
    swapoff -a 2>/dev/null
    # Unmount, the last mounted first, all but what the machine runs on
    # (the store is the one that stays, with the programs of this script).
    while read -r _ mp _; do
      case $mp in
        / | /proc | /proc/* | /sys | /sys/* | /dev | /dev/* | /run | /run/* | /nix | /nix/store) continue ;;
      esac
      umount -- "$mp" 2>/dev/null || mount -o remount,ro -- "$mp" 2>/dev/null
    done < <(tac /proc/mounts)
    sync
    mount -o remount,ro / 2>/dev/null
    exit 0
  '';

  ctrlaltdel = pkgs.writeScript "runit-ctrlaltdel" ''
    #!${sh}
    exec /run/current-system/sw/bin/systemctl reboot
  '';

  # rcctl: unit-rc as the tool that talks to it (list, start, stop, …)
  rcctl = pkgs.runCommand "rcctl" { } ''
    mkdir -p $out/bin
    ln -s ${unitTools}/bin/unit-rc $out/bin/rcctl
  '';
in

{
  options.runit = {
    verbose = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether unit-rc says every service it starts and stops in
        {file}`/run/uncaught-logs/unit-rc` (failures are there anyway).
      '';
    };
  };

  config = lib.mkIf (config.nixithos.init == "runit") {
    system.build.runitInit = init;

    environment.etc = {
      "runit/1".source = stage1;
      "runit/2".source = stage2;
      "runit/3".source = stage3;
      "runit/ctrlaltdel".source = ctrlaltdel;
    };

    # sv, rcctl; not runit-init (its 0 and 6 are for systemctl, which stops
    # the units in order first: poweroff & co. are the shim's)
    environment.systemPackages = [
      (pkgs.runCommand "runit-tools" { } ''
        mkdir -p $out/bin
        for p in sv runsvchdir chpst svlogd; do
          ln -s ${pkgs.runit}/bin/$p $out/bin/
        done
      '')
      rcctl
    ];

    warnings = lib.optional (initCfg.earlyGetty != null) ''
      s6.init.earlyGetty is a feature of s6-linux-init; with nixithos.init = "runit"
      it does nothing.
    '';
  };
}
