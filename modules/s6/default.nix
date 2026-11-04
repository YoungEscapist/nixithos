# s6 as init and service manager.
#
#   PID 1          s6-linux-init, which becomes s6-svscan on /run/service
#   services       s6-rc, driving that supervision tree from a compiled
#                  database that lives in the Nix store
#   the database   built from the system's unit files by `unitc` (see
#                  ../compat/units.nix), plus whatever is declared natively
#                  through `s6.rc.services`
#
# With nixithos.init = "dinit" (../dinit) the database holds dinit's service
# descriptions instead, and what is here about s6-linux-init is left out; the
# rest (the runtime, the options of logging and native services, the fd
# holder) is shared.  The services of users follow: their managers are
# dinit --user then, on descriptions from the same units.  With "runit"
# (../runit) the descriptions are the same, in runit/, and unit-rc reads
# them; the managers of users stay s6 trees there.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib) mkOption types;
  cfg = config.s6;
  isS6 = config.nixithos.init == "s6";
  # (the managers of users: dinit --user, or else an s6 tree)
  userDinit = config.nixithos.init == "dinit";

  # (dinit) where the database of the running configuration is: the services
  # are read from it and refer to their unit data through it, so that their
  # descriptions do not change from one configuration to the next unless
  # their units do
  live = "/run/units/.db";

  runtime = pkgs.nixithos.unitRuntime.override {
    logDir = cfg.logging.directory;
    logScript = cfg.logging.script;
  };

  nativeServiceModule =
    { name, config, ... }:
    {
      options = {
        type = mkOption {
          type = types.enum [
            "longrun"
            "oneshot"
            "bundle"
          ];
          description = "Kind of s6-rc service.";
        };
        run = mkOption {
          type = types.nullOr types.lines;
          default = null;
          description = "Longruns: the run script, including its `#!` line.";
        };
        finish = mkOption {
          type = types.nullOr types.lines;
          default = null;
          description = "Longruns: the optional finish script.";
        };
        up = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Oneshots: the command line run to start the service (execline syntax).";
        };
        down = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Oneshots: the command line run to stop the service.";
        };
        notificationFd = mkOption {
          type = types.nullOr types.ints.unsigned;
          default = null;
          description = "Longruns: descriptor on which the daemon announces readiness.";
        };
        dependencies = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = "Services that must be up before this one.";
        };
        contents = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = "Bundles: the services this name stands for.";
        };
        wantedByDefault = mkOption {
          type = types.bool;
          default = false;
          description = "Whether to start this service at boot.";
        };
        files = mkOption {
          type = types.attrsOf (
            types.submodule {
              options = {
                text = mkOption {
                  type = types.str;
                  description = "The contents of the file.";
                };
                mode = mkOption {
                  description = "The permissions of the file, in octal.";
                  type = types.str;
                  default = "0644";
                };
              };
            }
          );
          default = { };
          example = {
            "timeout-up".text = "30000\n";
            "data/config".text = "…";
          };
          description = ''
            Further files of the service definition directory, by relative
            path: `timeout-up`, `producer-for`, anything under `data/` or
            `env/`, and so on.  See s6-rc-compile's documentation.
          '';
        };
      };

      config.files = lib.mkMerge [
        (lib.mkIf (config.run != null) {
          run = {
            text = config.run;
            mode = "0755";
          };
        })
        (lib.mkIf (config.finish != null) {
          finish = {
            text = config.finish;
            mode = "0755";
          };
        })
        (lib.mkIf (config.up != null) { up.text = config.up + "\n"; })
        (lib.mkIf (config.down != null) { down.text = config.down + "\n"; })
        (lib.mkIf (config.notificationFd != null) {
          "notification-fd".text = "${toString config.notificationFd}\n";
        })
      ];
    };

  nativeJSON = pkgs.writeText "s6-rc-native-services.json" (
    builtins.toJSON {
      services = lib.mapAttrs (_: svc: {
        inherit (svc)
          type
          dependencies
          contents
          files
          ;
      }) cfg.rc.services;
      default = lib.attrNames (lib.filterAttrs (_: svc: svc.wantedByDefault) cfg.rc.services);
    }
  );

  userNativeJSON = pkgs.writeText "s6-rc-native-user-services.json" (
    builtins.toJSON {
      services = lib.mapAttrs (_: svc: {
        inherit (svc)
          type
          dependencies
          contents
          files
          ;
      }) cfg.user.rc.services;
      default = lib.attrNames (lib.filterAttrs (_: svc: svc.wantedByDefault) cfg.user.rc.services);
    }
  );

  # What a user's systemd finds: the units NixOS generates (/etc/systemd/user),
  # and below them those of the packages in the system profile, which it
  # looks for in $XDG_DATA_DIRS/systemd/user (ayatana's indicators are only
  # installed, not listed in systemd.packages).  A name both have is the
  # generated one's; its drop-ins and .wants apply either way.
  userUnitsAll =
    pkgs.runCommand "user-units-all"
      {
        generated = config.system.build.userUnits;
        profile = config.system.path;
        preferLocalBuild = true;
        allowSubstitutes = false;
      }
      ''
        mkdir $out
        for f in "$generated"/*; do ln -s "$f" $out/; done
        for d in "$profile/share/systemd/user" "$profile/lib/systemd/user"; do
          [ -d "$d" ] || continue
          for f in "$d"/*; do
            [ -f "$f" ] || continue
            [ -e "$out/''${f##*/}" ] || ln -s "$(readlink -f "$f")" "$out/''${f##*/}"
          done
        done
      '';

  systemServices =
    if isS6 then
      ''
        unitc \
          --units "$units" \
          --out "$out" \
          --runtime ${runtime}/bin/unit-runtime \
          --bash ${pkgs.runtimeShell} \
          --fdholder unit-fdholder \
          --notification-fd ${toString runtime.notificationFd} \
          --native ${nativeJSON}
        # Two databases of the same services; see unitc.
        s6-rc-compile -v1 "$out/compiled-boot" "$out/source-boot"
        s6-rc-compile -v1 "$out/compiled" "$out/source"
        ln -s "$units" "$out/units"
      ''
    else
      ''
        # dinit's descriptions (dinit/, or runit/ for unit-rc), with every
        # path in them through the database of the running configuration
        unitc \
          --init ${config.nixithos.init} \
          --units "$units" \
          --out "$out" \
          --final-out ${live} \
          --runtime ${live}/bin/unit-runtime \
          --supervise ${live}/bin/unit-supervise \
          --execlineb ${pkgs.execline}/bin/execlineb \
          --catchall-log /run/uncaught-logs/services \
          --bash ${pkgs.runtimeShell} \
          --fdholder unit-fdholder \
          --notification-fd ${toString runtime.notificationFd} \
          --native ${nativeJSON}
        mkdir "$out/bin"
        ln -s ${runtime}/bin/unit-runtime ${pkgs.nixithos.unitTools}/bin/unit-supervise "$out/bin/"
        ${lib.optionalString (config.nixithos.init == "openrc") ''
          # the tools of the scripts (unitc --init openrc), through the database
          ln -s ${pkgs.nixithos.unitTools}/bin/unit-svwait "$out/bin/"
          ln -s ${pkgs.nixithos.openrc}/sbin/openrc-run ${pkgs.nixithos.openrc}/sbin/start-stop-daemon "$out/bin/"
          for p in mkdir rm timeout; do ln -s ${pkgs.coreutils}/bin/$p "$out/bin/"; done
        ''}
        ln -s "$units" "$out/units"
      '';

  # (dinit) where a user's manager has the database it runs on: a link that
  # user-manager puts in the manager's own directory (UNIT_USER_STATE, which
  # differs from one user to the next), and moves at a switch.  The database
  # is the same for every user, so the path cannot be written into it as the
  # system's is; dinit fills the variable in when it reads a description
  # (dinit-service(5), VARIABLE SUBSTITUTION), and the runtime, which has it
  # in its environment as every service of the manager does, when it reads
  # the unit data.  A description stays the same from one configuration to
  # the next as long as its unit does, which is what the switch compares;
  # and a manager whose switch did not happen (or failed) goes on with the
  # database it was started on, whatever the system's is by then.
  userLive = "\${UNIT_USER_STATE}/db";

  userServices =
    if !userDinit then
      ''
        unitc \
          --scope user \
          --units "$userUnits" \
          --out "$out/user" \
          --runtime ${runtime}/bin/unit-runtime \
          --bash ${pkgs.runtimeShell} \
          --fdholder unit-fdholder \
          --notification-fd ${toString runtime.notificationFd} \
          --native ${userNativeJSON}
        s6-rc-compile -v1 "$out/user/compiled-boot" "$out/user/source-boot"
        s6-rc-compile -v1 "$out/user/compiled" "$out/user/source"
      ''
    else
      ''
        # dinit --user (see userLive); what has no logger of its own goes
        # where the manager's output goes, as under s6
        unitc \
          --init dinit \
          --scope user \
          --units "$userUnits" \
          --out "$out/user" \
          --final-out ${lib.escapeShellArg userLive} \
          --runtime ${lib.escapeShellArg "${userLive}/bin/unit-runtime"} \
          --supervise ${lib.escapeShellArg "${userLive}/bin/unit-supervise"} \
          --execlineb ${pkgs.execline}/bin/execlineb \
          --catchall-console \
          --bash ${pkgs.runtimeShell} \
          --fdholder unit-fdholder \
          --notification-fd ${toString runtime.notificationFd} \
          --native ${userNativeJSON}
        mkdir "$out/user/bin"
        ln -s ${runtime}/bin/unit-runtime ${pkgs.nixithos.unitTools}/bin/unit-supervise "$out/user/bin/"
      '';

  database =
    pkgs.runCommand (if isS6 then "s6-rc-database" else "${config.nixithos.init}-database")
      {
        nativeBuildInputs = [
          pkgs.buildPackages.nixithos.unitc
          pkgs.buildPackages.s6-rc
        ];
        units = config.system.build.systemUnits;
        userUnits = userUnitsAll;
        preferLocalBuild = true;
        allowSubstitutes = false;
      }
      ''
        ${systemServices}
        # The services of users: the same, from systemd.user.*, for the
        # service manager each user gets (../../pkgs/user-manager): an s6
        # supervision tree (also under runit), or dinit --user.
        mkdir "$out/user"
        ${userServices}
        ln -s "$userUnits" "$out/user/units"
      '';

  script = name: text: {
    inherit name;
    path = pkgs.writeScript name text;
  };

  # s6-linux-init runs these; see s6-linux-init-maker(1).
  skeleton = pkgs.linkFarm "s6-linux-init-skel" [
    (script "rc.init" ''
      #!${pkgs.runtimeShell}
      # Stage 2: s6-svscan is running as PID 1; bring the services up.
      PATH=${
        lib.makeBinPath [
          pkgs.coreutils
          pkgs.util-linux
          pkgs.s6-rc
          pkgs.s6
        ]
      }

      # The run image was copied over /run with the modes it has in the Nix
      # store, i.e. without write permission.
      chmod 0755 /run /run/service

      # Tells `systemctl` that the boot transaction is still under way.
      mkdir -p /run/units
      : > /run/units/.booting
      trap 'rm -f /run/units/.booting /run/units/.switching' EXIT

      db=$(readlink -f /run/booted-system/s6-db)

      # Keep the database that is in use from being garbage-collected, also
      # when it is no longer the one of the current system.
      ln -sfn "$db" /nix/var/nix/gcroots/s6-rc-live 2>/dev/null

      # 1. Boot on the database in which every ordering constraint is a
      #    dependency: s6-rc starts everything in order, in parallel.
      s6-rc-init -c "$db/compiled-boot" -l /run/s6-rc /run/service || exit 1

      # s6-rc's report of the boot goes to the console, as systemd's status
      # lines do - but not while a service has the console's terminal (a
      # getty on tty1: see console_mark in unit-runtime), as with systemd.
      # Its login prompt is there by then, and what is typed at it.
      console_status() {
        local line marks
        shopt -s nullglob
        while IFS= read -r line; do
          marks=(/run/units/.on-console/*)
          (( ''${#marks[@]} )) || printf '%s\n' "$line"
        done
      }

      s6-rc -v${toString cfg.rc.verbosity} -u change default 2>&1 | console_status
      status=''${PIPESTATUS[0]}

      # `systemctl start` brings a service up by hand while s6-rc is busy, and
      # holds this lock (shared) until it is up: from here to the update
      # nothing is started that the look below would miss.
      exec {switch_lock}>> /run/units/.switch-lock
      flock -x "$switch_lock"

      # While the database is switched, service directories come and go for a
      # moment: `systemctl` waits for this file to be gone before it answers.
      : > /run/units/.switching

      # A unit may have started a service by hand while s6-rc was busy with
      # the transaction above (`systemctl start`, a timer that fired early):
      # it is running, and s6-rc has it down.  The update below would replace
      # its directory and take it away; telling s6-rc makes it one of the
      # services that stay.
      up=" $(s6-rc -a list | tr '\n' ' ') "
      known=" $(s6-rc-db -c "$db/compiled-boot" list services | tr '\n' ' ') "
      adopt=()
      for d in /run/service/*; do
        a=''${d##*/}
        [[ $known == *" $a "* && $up != *" $a "* ]] || continue
        [[ $(s6-svstat -o up "$d" 2>/dev/null) == true ]] && adopt+=("$a")
      done
      if (( ''${#adopt[@]} )); then
        echo "rc.init: services started during the boot: ''${adopt[*]}"
        s6-rc -b -u change "''${adopt[@]}"
      fi

      # 2. Move to the database that only has real requirements, so that from
      #    now on a service can be stopped or replaced without dragging along
      #    everything that merely starts after it.  Nothing restarts here.
      # (-b: a timer's job that was waiting for the end of the transaction
      # may have taken the lock first; the update waits for it.  -v1: its
      # progress report is eight lines on the console, under the login
      # prompt of tty1 by now, which tests read the screen of.)
      if ! s6-rc-update -b -v1 "$db/compiled"; then
        echo "rc.init: could not switch to the steady service database" >&2
        exit 1
      fi
      rm -f /run/units/.switching
      exec {switch_lock}>&-

      # 3. A unit that failed without being required by anything has still
      #    kept the units ordered after it from starting.  They can go now.
      if [ "$status" != 0 ]; then
        up=" $(s6-rc -a list | tr '\n' ' ') "
        late=()
        while IFS=$'\t' read -r unit kind type rank boot atom atoms start; do
          [ "$boot" = 1 ] || continue
          state=
          [ -r "/run/units/$unit/state" ] && state=$(< "/run/units/$unit/state")
          [ "$state" = failed ] && continue
          for a in $atoms; do
            [[ $up == *" $a "* ]] || late+=("$a")
          done
        done < "$db/index.tsv"
        if (( ''${#late[@]} )); then
          echo "rc.init: starting what was held back by failed units: ''${late[*]}"
          s6-rc -v${toString cfg.rc.verbosity} -u change "''${late[@]}" 2>&1 | console_status
        fi
      fi

      # 4. The boot is over.  A generation that was on trial (boot
      #    assessment, nixithos.bootAssessment) is good now.
      if [ -r /etc/units/boot-hook ] && read -r hook < /etc/units/boot-hook && [ -x "$hook" ]; then
        timeout 120 "$hook" good || true
      fi
      exit 0
    '')
    (script "runlevel" ''
      #!${pkgs.runtimeShell}
      # telinit: there is only one machine state here.
      exit 0
    '')
    (script "rc.shutdown" ''
      #!${pkgs.runtimeShell}
      PATH=${
        lib.makeBinPath [
          pkgs.coreutils
          pkgs.s6-rc
          pkgs.s6
        ]
      }

      # The steady database has no ordering in it; stop the services rank by
      # rank instead, last started first.
      live=$(readlink -f /run/s6-rc/compiled)
      ranks=''${live%/*}/ranks.tsv
      if [ -r "$ranks" ]; then
        up=" $(s6-rc -a list | tr '\n' ' ') "
        prev=
        batch=()
        flush() {
          (( ''${#batch[@]} )) && s6-rc -v${toString cfg.rc.verbosity} -b -d change "''${batch[@]}"
          batch=()
        }
        while IFS=$'\t' read -r rank atom; do
          [ "$rank" = "$prev" ] || flush
          prev=$rank
          [[ $up == *" $atom "* ]] && batch+=("$atom")
        done < <(sort -rn "$ranks")
        flush
      fi

      exec s6-rc -v${toString cfg.rc.verbosity} -bDa -t ${toString cfg.init.shutdownTimeout} change
    '')
    (script "rc.shutdown.final" ''
      #!${pkgs.runtimeShell}
      ${cfg.init.finalCommands}
      exit 0
    '')
  ];

  initBase =
    pkgs.runCommand "s6-linux-init-base"
      {
        nativeBuildInputs = [ pkgs.buildPackages.s6-linux-init ];
        preferLocalBuild = true;
        allowSubstitutes = false;
      }
      ''
        s6-linux-init-maker \
          -c "$out" \
          -f ${skeleton} \
          -V ${toString cfg.init.verbosity} \
          -p ${lib.escapeShellArg cfg.init.path} \
          -m 0022 \
          -t 2 \
          -q ${toString cfg.init.finalSleep} \
          -D default \
          -N \
          ${lib.optionalString (cfg.init.limits != "") "-R ${lib.escapeShellArg cfg.init.limits}"} \
          ${lib.optionalString cfg.init.logToConsole "-1"} \
          ${lib.optionalString (cfg.init.earlyGetty != null) "-G ${lib.escapeShellArg cfg.init.earlyGetty}"} \
          ${
            lib.concatStringsSep " " (
              lib.mapAttrsToList (n: v: "-e ${lib.escapeShellArg "${n}=${v}"}") cfg.init.environment
            )
          } \
          "$out"

        # The store cannot hold FIFOs.  Stage 2 creates the two that belong
        # into the run image right before it starts s6-linux-init.
        find "$out" -type p -print -delete
      '';
in

{
  options.s6 = {
    init = {
      verbosity = mkOption {
        type = types.ints.unsigned;
        default = 1;
        description = "Verbosity of s6-linux-init during boot.";
      };

      logToConsole = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Whether to copy everything that reaches the catch-all logger (boot
          progress, output of services without a logger of their own) to
          {file}`/dev/console`.  The log itself is in {file}`/run/uncaught-logs`.
        '';
      };

      earlyGetty = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = lib.literalExpression ''"''${pkgs.util-linux}/bin/agetty tty12 linux"'';
        description = ''
          A command to supervise from the very first moment of stage 2, before
          any service has been started.  Meant for a getty on a spare terminal:
          it keeps the machine reachable when the boot does not get as far as
          the regular ones.
        '';
      };

      finalSleep = mkOption {
        type = types.ints.unsigned;
        default = 3000;
        description = ''
          At shutdown, how long (in milliseconds) to wait between sending
          SIGTERM and SIGKILL to the processes that are still around once all
          services have been stopped.
        '';
      };

      shutdownTimeout = mkOption {
        type = types.ints.unsigned;
        default = 120000;
        description = "Upper bound, in milliseconds, for stopping all services at shutdown.";
      };

      finalCommands = mkOption {
        type = types.lines;
        default = "";
        description = ''
          Shell commands run at the very end of shutdown, after everything has
          been killed and before file systems are unmounted.
        '';
      };

      path = mkOption {
        type = types.str;
        default = lib.concatStringsSep ":" [
          (lib.makeBinPath [
            pkgs.s6
            pkgs.s6-rc
            pkgs.s6-linux-init
            pkgs.execline
          ])
          "/run/wrappers/bin"
          "/run/current-system/sw/bin"
        ];
        defaultText = lib.literalMD "the s6 tools, then the system profile";
        description = "`PATH` of PID 1, inherited by services that do not set their own.";
      };

      environment = mkOption {
        type = types.attrsOf types.str;
        default = { };
        description = "Environment of PID 1, inherited by natively defined services.";
      };
    };

    rc = {
      verbosity = mkOption {
        type = types.ints.unsigned;
        default = 2;
        description = "Verbosity of s6-rc at boot and shutdown; 2 reports every service transition.";
      };

      services = mkOption {
        type = types.attrsOf (types.submodule nativeServiceModule);
        default = { };
        description = ''
          Services defined directly in s6-rc terms, next to the ones compiled
          from `systemd.services` and friends.  They share one database, so
          they can depend on compiled services by their s6-rc name (the unit
          name without `.service`, or the full name for other unit types).
        '';
      };
    };

    user.rc.services = mkOption {
      type = types.attrsOf (types.submodule nativeServiceModule);
      default = { };
      description = ''
        Like {option}`s6.rc.services`, for the supervision tree each user gets
        next to their `systemd.user.*` units.
      '';
    };

    logging = {
      directory = mkOption {
        type = types.path;
        default = "/var/log/s6";
        description = "Each service logs into a subdirectory of this, named after the service.";
      };

      script = mkOption {
        type = types.str;
        default = "n10 s1000000 T";
        description = ''
          s6-log directives applied to every service log: by default, keep 10
          archives of 1 MB each and prefix lines with an ISO 8601 timestamp.
        '';
      };
    };
  };

  config = lib.mkMerge [ (lib.mkIf isS6 {
    system.build.s6InitBase = initBase;

    system.systemBuilderCommands = ''
      ln -s ${initBase} $out/s6-init
    '';

    environment.systemPackages = [ pkgs.s6-linux-init ];
  }) {
    # (the unit database of either init: the name is from before there was
    # a choice, and stays, as /run/current-system/s6-db does)
    system.build.s6Database = database;
    system.build.unitRuntime = runtime;

    # Sockets of .socket units are bound early and parked here until their
    # service picks them up (and again whenever it restarts).
    s6.rc.services.unit-fdholder = {
      type = "longrun";
      notificationFd = 3;
      run = ''
        #!${pkgs.execline}/bin/execlineb -P
        ${pkgs.execline}/bin/fdmove 1 3
        ${pkgs.execline}/bin/if { ${pkgs.coreutils}/bin/mkdir -p /run/units }
        ${pkgs.s6}/bin/s6-fdholder-daemon -1 -n 1024 -i data/rules -- /run/units/.fdholder
      '';
      files = {
        "data/rules/uid/0/allow".text = "";
        "data/rules/uid/0/env/S6_FDHOLDER_STORE_REGEX".text = "^unit:\n";
        "data/rules/uid/0/env/S6_FDHOLDER_RETRIEVE_REGEX".text = "^unit:\n";
        "data/rules/uid/0/env/S6_FDHOLDER_LIST".text = "\n";
      };
    };

    # Sockets of a user's .socket units, as for the system's.
    s6.user.rc.services.unit-fdholder = {
      type = "longrun";
      notificationFd = 3;
      wantedByDefault = true;
      run = ''
        #!${pkgs.runtimeShell}
        state=''${UNIT_USER_STATE:-$XDG_RUNTIME_DIR}
        mkdir -p "$state/units"
        exec ${pkgs.s6}/bin/s6-fdholder-daemon -1 -n 256 -i data/rules -- "$state/units/.fdholder" >&3
      '';
      files = {
        # the socket is in the user's own runtime directory
        "data/rules/uid/default/allow".text = "";
        "data/rules/uid/default/env/S6_FDHOLDER_STORE_REGEX".text = "^unit:\n";
        "data/rules/uid/default/env/S6_FDHOLDER_RETRIEVE_REGEX".text = "^unit:\n";
        "data/rules/uid/default/env/S6_FDHOLDER_LIST".text = "\n";
      };
    };

    system.systemBuilderCommands = ''
      ln -s ${database} $out/s6-db
    '';

    # (with dinit too: the loggers, the fd holder and the supervisor of the
    # users' managers are s6 programs)
    environment.systemPackages = [
      pkgs.s6
      pkgs.s6-rc
      pkgs.s6-portable-utils
      pkgs.execline
    ];

    # One control group per service; see unit-runtime.
    boot.specialFileSystems."/sys/fs/cgroup" = {
      device = "cgroup2";
      fsType = "cgroup2";
      options = [
        "nosuid"
        "nodev"
        "noexec"
      ];
    };
  } ];
}
