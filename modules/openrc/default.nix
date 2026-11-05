# OpenRC as init and service manager (nixithos.init = "openrc").
#
#   PID 1     openrc-init, which runs `openrc` for the runlevels sysinit, boot
#             and default in turn; the init script of NixOS (below) sets the
#             runtime directory up first: the database in use
#             (/run/units/.db, as with dinit), the booting mark
#   services  scripts for openrc-run, which unitc writes (openrc/init.d in the
#             database).  OpenRC finds them through /run/units/.db/openrc
#             (compiled into it, see ../../pkgs/openrc), so that a switch
#             moves the link and `rc-update -u` reads the dependencies again.
#             OpenRC itself knows what starts after what (need, want, after);
#             the processes run under unit-supervise, which keeps the contract
#             of s6-supervise (readiness, finish, the status in
#             /run/units/.sv/ATOM), and the oneshots are commands
#   runlevels sysinit and boot are empty (stage 1 and 2 of NixOS did that
#             work); default lists the boot services so OpenRC can order
#             them; `boot` waits for them and then says the boot is over;
#             shutdown has `final` (below)
#   shutdown  `systemctl poweroff` and friends tell openrc-init (openrc-shutdown),
#             which stops every service in the reverse order of the start,
#             starts `final` (s6.init.finalCommands, unmounting), sends
#             the processes that are left TERM and then KILL, and powers off
#
# The options of ../s6 that are not about s6-linux-init or s6-rc apply here
# too: s6.init.path, .environment, .limits and .finalCommands, s6.logging,
# s6.rc.services (native services: unitc writes scripts for them).
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.openrc;
  initCfg = config.s6.init;
  db = config.system.build.s6Database;
  sh = pkgs.runtimeShell;
  unitTools = pkgs.nixithos.unitTools;
  openrc = pkgs.nixithos.openrc;

  limits = import ../init-limits.nix { inherit lib; } initCfg.limits;

  binPath = lib.makeBinPath [
    pkgs.coreutils
    pkgs.util-linux
  ];

  # what the services of the machine start with: the environment of
  # openrc-init (dinit's -e, or s6-linux-init's)
  environment = [
    "PATH=${openrc}/bin:${unitTools}/bin:${initCfg.path}"
  ]
  ++ lib.optional (!cfg.verbose) "EINFO_QUIET=yes"
  ++ lib.mapAttrsToList (n: v: "${n}=${v}") initCfg.environment;

  init = pkgs.writeScriptBin "init" ''
    #!${sh}
    # Stage 2 of NixOS is done; OpenRC takes over as PID 1.
    PATH=${lib.makeBinPath [ pkgs.coreutils ]}

    # hard limits of PID 1, inherited by everything (s6.init.limits)
    ${limits}

    mkdir -p /run/units /run/uncaught-logs
    # The unit database of this configuration: OpenRC reads the services from
    # it, and the services find their unit data in it.  A switch points it at
    # another one (switch-to-configuration).
    ln -sfn ${db} /run/units/.db
    # (kept from the garbage collector while it is in use, also when it is no
    # longer the one of the current system)
    ln -sfn ${db} /nix/var/nix/gcroots/units-live 2>/dev/null
    # Tells `systemctl` that the boot is still under way; the `boot` service
    # takes it away at the end (unit-runtime booted).
    : > /run/units/.booting

    exec env -i ${lib.concatMapStringsSep " " lib.escapeShellArg environment} \
      ${openrc}/sbin/openrc-init
  '';

  # the last of the shutdown, in the runlevel of that name: OpenRC has stopped
  # the services by now
  final = pkgs.writeScript "openrc-final" ''
    #!${openrc}/sbin/openrc-run
    description="Last steps of the shutdown"

    start() {
      PATH=${binPath}
      ${initCfg.finalCommands}

      sync
      swapoff -a 2>/dev/null
      # Unmount, the last mounted first, all but what the machine runs on
      # (the store is the one that stays, with the programs of this script).
      tac /proc/mounts | while read -r _ mp _; do
        case $mp in
          / | /proc | /proc/* | /sys | /sys/* | /dev | /dev/* | /run | /run/* | /nix | /nix/store) continue ;;
        esac
        umount -- "$mp" 2>/dev/null || mount -o remount,ro -- "$mp" 2>/dev/null
      done
      sync
      mount -o remount,ro / 2>/dev/null
      return 0
    }
  '';

  # /etc/runlevels: the runlevels, with what is in them
  runlevels = pkgs.runCommand "openrc-runlevels" { } ''
    mkdir -p $out/sysinit $out/boot $out/shutdown $out/single
    ln -s /run/units/.db/openrc/runlevels/default $out/default
    ln -s /etc/init.d/final $out/shutdown/final
  '';

  # What a script finds when it is run by rc-service from somewhere else than
  # openrc-init: OpenRC leaves a shell's environment out (but for a few
  # variables) and adds what is here.
  profileEnv = pkgs.writeText "profile.env" ''
    PATH='${openrc}/bin:${unitTools}/bin:${initCfg.path}'
  '';

  rcConf = pkgs.writeText "rc.conf" ''
    # Generated; see modules/openrc.
    #
    # The services start in parallel, each once what it needs is up.
    rc_parallel="YES"
    rc_interactive="NO"
    rc_logger="NO"
    rc_verbose="NO"
    rc_default_runlevel="default"
    rc_shell="${sh}"
    # What start-stop-daemon does with a service's processes when stopping
    # them is in each script.
    rc_cgroup_cleanup="NO"
    # The services are not started again by OpenRC when they are found
    # crashed: unit-supervise does that.
    rc_crashed_stop="NO"
    rc_crashed_start="NO"
  '';
in

{
  options.openrc = {
    verbose = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether OpenRC says every service it starts and stops on the console.
        Without it, only warnings and errors get there.
      '';
    };
  };

  config = lib.mkIf (config.nixithos.init == "openrc") {
    system.build.openrcInit = init;

    environment.etc = {
      "rc.conf".source = rcConf;
      "profile.env".source = profileEnv;
      "runlevels".source = runlevels;
      "init.d/final".source = final;
    };

    # openrc-init needs a place for what it is told: its fifo, in /run/openrc
    # (it makes it); rc-service, rc-status and rc-update for the people.  Not
    # openrc-shutdown, halt & co.: those of the systemd shim go through
    # systemctl.
    environment.systemPackages = [
      (pkgs.runCommand "openrc-tools" { } ''
        mkdir -p $out/bin
        for p in rc-service rc-status rc-update rc-sstat; do
          ln -s ${openrc}/bin/$p $out/bin/
        done
      '')
      pkgs.nixithos.openrcCtl
    ];

    warnings = lib.optional (initCfg.earlyGetty != null) ''
      s6.init.earlyGetty is a feature of s6-linux-init; with nixithos.init = "openrc"
      it does nothing.
    '';
  };
}
