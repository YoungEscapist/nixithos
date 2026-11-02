# dinit as init and service manager (nixithos.init = "dinit").
#
#   PID 1          dinit, which stage 2 hands over to through `init` below
#   services       the descriptions unitc writes from the system's units
#                  (dinit/ in the unit database, see ../s6/default.nix),
#                  read through /run/units/.db, the database of the
#                  configuration that runs; the processes of a unit run
#                  under unit-supervise, which does for them what
#                  s6-supervise does under s6
#                  (../../pkgs/unit-tools/unit-supervise.c)
#   shutdown       `systemctl poweroff` and friends stop the units in the
#                  reverse order of their start, then dinit stops the rest;
#                  its shutdown program kills what is left, runs
#                  /etc/dinit/shutdown-hook and unmounts
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
  cfg = config.dinit;
  initCfg = config.s6.init;
  db = config.system.build.s6Database;

  environmentFile = pkgs.writeText "dinit-environment" (
    lib.concatStringsSep "\n" (
      [
        "!clear"
        "PATH=${lib.makeBinPath [ pkgs.dinit ]}:${initCfg.path}"
      ]
      ++ lib.mapAttrsToList (n: v: "${n}=${v}") initCfg.environment
    )
    + "\n"
  );

  # s6.init.limits is in the letters of s6-softlimit; these are ulimit's
  ulimitFlags = {
    a = [ "v" ];
    c = [ "c" ];
    d = [ "d" ];
    f = [ "f" ];
    l = [ "l" ];
    m = [
      "d"
      "s"
      "l"
      "v"
    ];
    o = [ "n" ];
    p = [ "u" ];
    r = [ "m" ];
    s = [ "s" ];
    t = [ "t" ];
  };
  limits = lib.concatMapStringsSep "\n" (
    item:
    let
      letter = builtins.substring 0 1 item;
      value = builtins.substring 1 (-1) item;
      flags =
        ulimitFlags.${letter} or (throw "s6.init.limits: unknown resource `${letter}' in `${item}'");
    in
    lib.concatMapStringsSep "\n" (
      f: "ulimit -H${f} ${if value == "=" then "unlimited" else value} 2>/dev/null"
    ) flags
  ) (lib.filter (x: x != "") (lib.splitString "," initCfg.limits));

  init = pkgs.writeScriptBin "init" ''
    #!${pkgs.runtimeShell}
    # Stage 2 is done; dinit takes over as PID 1.
    PATH=${lib.makeBinPath [ pkgs.coreutils ]}

    # hard limits of PID 1, inherited by everything (s6.init.limits)
    ${limits}

    mkdir -p /run/units /run/uncaught-logs
    # The unit database of this configuration: dinit reads the services from
    # it, and the services find their unit data in it.  A switch points it at
    # another one (switch-to-configuration).
    ln -sfn ${db} /run/units/.db
    # (kept from the garbage collector while it is in use, also when it is no
    # longer the one of the current system)
    ln -sfn ${db} /nix/var/nix/gcroots/units-live 2>/dev/null
    # Tells `systemctl` that the boot is still under way; the `boot` service
    # takes it away at the end (unit-runtime booted).
    : > /run/units/.booting

    exec ${pkgs.dinit}/bin/dinit \
      -d /run/units/.db/dinit \
      -p /run/dinitctl \
      -e ${environmentFile} \
      --log-file /run/uncaught-logs/dinit \
      ${lib.optionalString (!cfg.verbose) "--quiet --console-level warn"} \
      -t boot
  '';
in

{
  options.dinit = {
    verbose = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether dinit reports every service it starts and stops on the
        console.  Without it, only failures and warnings get there; all of
        it is in {file}`/run/uncaught-logs/dinit` either way.
      '';
    };
  };

  config = lib.mkIf (config.nixithos.init == "dinit") {
    system.build.dinitInit = init;

    # dinitctl & co., not dinit's halt/poweroff/reboot/shutdown: those of the
    # systemd shim stop the units in order first (see systemctl's power)
    environment.systemPackages = [
      (pkgs.runCommand "dinit-tools" { } ''
        mkdir -p $out/bin
        for p in dinit dinitctl dinit-check dinit-monitor; do
          ln -s ${pkgs.dinit}/bin/$p $out/bin/
        done
        ln -s ${pkgs.dinit}/share $out/share
      '')
    ];

    # Run by dinit's shutdown program once every other process is gone, before
    # it unmounts the file systems (which it still does: the hook does not
    # unmount, so it says so with its status).
    environment.etc."dinit/shutdown-hook" = {
      mode = "0755";
      text = ''
        #!${pkgs.runtimeShell}
        ${initCfg.finalCommands}
        exit 1
      '';
    };

    warnings =
      lib.optional (initCfg.earlyGetty != null) ''
        s6.init.earlyGetty is a feature of s6-linux-init; with nixithos.init = "dinit"
        it does nothing.
      '';
  };
}
