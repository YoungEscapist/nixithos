# The units a NixOS system takes for granted because systemd ships them:
# the standard targets, and the early-boot services that are part of systemd
# itself.
#
# Targets are reproduced as they are, since they only carry ordering.  The
# services get an implementation that does not involve systemd.  They keep
# their systemd unit names, so that the partial definitions spread over the
# upstream modules (`systemd.services.systemd-udevd.restartTriggers`,
# `systemd.services.systemd-modules-load.wantedBy`, …) and every
# `After=systemd-….service` still land on the right unit; `X-S6-Name` gives
# each of them a plain name on the s6 side.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  early = {
    unitConfig.DefaultDependencies = false;
  };

  target = description: extra: lib.recursiveUpdate { inherit description; } extra;

  loadModules = pkgs.writeShellScript "modules-load" ''
    # Load the modules listed in modules-load.d(5) files.
    shopt -s nullglob
    rc=0
    declare -A seen
    for dir in /etc/modules-load.d /run/modules-load.d; do
      for file in "$dir"/*.conf; do
        name=''${file##*/}
        [[ -n ''${seen[$name]-} ]] && continue
        seen[$name]=1
        while read -r module _; do
          [[ -z $module || $module == \#* || $module == \;* ]] && continue
          ${pkgs.kmod}/bin/modprobe -ab -- "$module" || rc=1
        done < "$file"
      done
    done
    exit $rc
  '';

  applySysctl = pkgs.writeShellScript "sysctl-apply" ''
    # Apply sysctl.d(5) files; later directories and names win.
    shopt -s nullglob
    declare -A files
    for dir in /usr/lib/sysctl.d /run/sysctl.d /etc/sysctl.d; do
      for file in "$dir"/*.conf; do
        files[''${file##*/}]=$file
      done
    done
    rc=0
    for name in $(printf '%s\n' "''${!files[@]}" | sort); do
      while IFS= read -r line; do
        line=''${line#"''${line%%[![:space:]]*}"}
        [[ -z $line || $line == \#* || $line == \;* || $line != *=* ]] && continue
        key=''${line%%=*}
        value=''${line#*=}
        key=''${key%"''${key##*[![:space:]]}"}
        value=''${value#"''${value%%[![:space:]]*}"}
        optional=0
        if [[ $key == -* ]]; then optional=1; key=''${key#-}; fi
        # sysctl.d allows either separator; "/" in a key stands for a literal dot
        if [[ $key == */* ]]; then path=/proc/sys/$key; else path=/proc/sys/''${key//.//}; fi
        matched=0
        for target in $path; do
          matched=1
          if ! printf '%s\n' "$value" > "$target" 2>/dev/null; then
            (( optional )) || { echo "cannot set $key = $value" >&2; rc=1; }
          fi
        done
        if (( ! matched && ! optional )); then
          echo "no such sysctl: $key" >&2
        fi
      done < "''${files[$name]}"
    done
    exit 0
  '';

  # systemd-vconsole-setup: keyboard layout and font of the virtual consoles,
  # from /etc/vconsole.conf (which console.nix writes).
  vconsoleSetup = pkgs.writeShellScript "vconsole-setup" ''
    export PATH=${lib.makeBinPath [ pkgs.kbd pkgs.coreutils ]}
    [ -r /etc/vconsole.conf ] || exit 0
    keymap= toggle= font= fontmap= unimap=
    while IFS== read -r key value; do
      case $key in ""|\#*) continue ;; esac
      value=''${value#[\"\']}
      value=''${value%[\"\']}
      case $key in
        KEYMAP) keymap=$value ;;
        KEYMAP_TOGGLE) toggle=$value ;;
        FONT) font=$value ;;
        FONT_MAP) fontmap=$value ;;
        FONT_UNIMAP) unimap=$value ;;
      esac
    done < /etc/vconsole.conf

    rc=0
    # (only the consoles that exist: a machine with no VT has none of them)
    ttys=
    for tty in /dev/tty0 /dev/tty1 /dev/tty2 /dev/tty3 /dev/tty4 /dev/tty5 /dev/tty6; do
      [ -c "$tty" ] && ttys="$ttys $tty"
    done
    [ -n "$ttys" ] || exit 0

    for tty in $ttys; do kbd_mode -u -C "$tty" 2>/dev/null || true; done
    if [ -n "$keymap" ]; then
      loadkeys -q -u -C /dev/tty0 "$keymap" $toggle || rc=1
    fi
    if [ -n "$font" ]; then
      # fonts by name: those of console.packages are in /etc/kbd
      if [ "''${font#/}" = "$font" ]; then
        for f in /etc/kbd/consolefonts/"$font".*; do
          [ -e "$f" ] && { font=$f; break; }
        done
      fi
      for tty in $ttys; do
        setfont -C "$tty" "$font" ''${fontmap:+-m "$fontmap"} ''${unimap:+-u "$unimap"} 2>/dev/null || rc=1
      done
    fi
    exit $rc
  '';

  seedFile = "/var/lib/random-seed";
in

{
  config = {
    # A console that appears later (the graphics driver's framebuffer taking
    # over from the firmware's) starts with the kernel's 256-glyph font and
    # the default keymap: set it up again, as systemd's 90-vconsole.rules
    # does.  Without it console.font (Cyrillic, say) was lost on every boot
    # where the driver came after vconsole-setup.
    services.udev.extraRules = ''
      ACTION=="add", SUBSYSTEM=="vtconsole", KERNEL=="vtcon*", RUN+="${vconsoleSetup}"
    '';

    systemd.targets = {
      # ---- boot ------------------------------------------------------------
      sysinit = target "System Initialization" {
        wants = [
          "local-fs.target"
          "swap.target"
        ];
        after = [
          "local-fs.target"
          "swap.target"
        ];
      };
      basic = target "Basic System" {
        requires = [ "sysinit.target" ];
        wants = [
          "sockets.target"
          "timers.target"
          "paths.target"
          "slices.target"
        ];
        after = [
          "sysinit.target"
          "sockets.target"
          "paths.target"
          "slices.target"
        ];
      };
      multi-user = target "Multi-User System" {
        requires = [ "basic.target" ];
        after = [ "basic.target" ];
        wants = [
          "getty.target"
          "remote-fs.target"
        ];
        unitConfig.AllowIsolate = true;
      };
      graphical = target "Graphical Interface" {
        requires = [ "multi-user.target" ];
        wants = [ "display-manager.service" ];
        after = [
          "multi-user.target"
          "display-manager.service"
        ];
        unitConfig.AllowIsolate = true;
      };
      rescue = target "Rescue Mode" {
        requires = [ "sysinit.target" ];
        after = [ "sysinit.target" ];
        unitConfig.AllowIsolate = true;
      };
      emergency = target "Emergency Mode" early;

      # ---- file systems ----------------------------------------------------
      local-fs-pre = target "Preparation for Local File Systems" early;
      local-fs = target "Local File Systems" (
        early
        // {
          after = [ "local-fs-pre.target" ];
        }
      );
      remote-fs-pre = target "Preparation for Remote File Systems" early;
      remote-fs = target "Remote File Systems" (
        early
        // {
          after = [ "remote-fs-pre.target" ];
        }
      );
      swap = target "Swaps" early;
      cryptsetup-pre = target "Preparation for Local Encrypted Volumes" early;
      cryptsetup = target "Local Encrypted Volumes" early;
      remote-cryptsetup = target "Remote Encrypted Volumes" early;

      # ---- activation points ----------------------------------------------
      sockets = target "Socket Units" { };
      timers = target "Timer Units" { };
      paths = target "Path Units" { };
      slices = target "Slice Units" { };
      getty = target "Login Prompts" { };

      # ---- network ----------------------------------------------------------
      network-pre = target "Preparation for Network" early;
      network = target "Network" (
        early
        // {
          after = [ "network-pre.target" ];
        }
      );
      network-online = target "Network is Online" (
        early
        // {
          after = [ "network.target" ];
        }
      );
      nss-lookup = target "Host and Network Name Lookups" early;
      nss-user-lookup = target "User and Group Name Lookups" early;
      rpcbind = target "RPC Port Mapper" early;

      # ---- clock ------------------------------------------------------------
      time-set = target "System Time Set" early;
      time-sync = target "System Time Synchronized" (
        early
        // {
          after = [ "time-set.target" ];
          wants = [ "time-set.target" ];
        }
      );

      # ---- hardware ---------------------------------------------------------
      sound = target "Sound Card" early;
      bluetooth = target "Bluetooth Support" early;
      printer = target "Printer Support" early;
      smartcard = target "Smart Card" early;

      # ---- shutdown (ordering only: s6-linux-init does the work) -----------
      shutdown = target "System Shutdown" early;
      umount = target "Unmount All Filesystems" early;
      final = target "Late Shutdown Services" early;
      reboot = target "System Reboot" early;
      poweroff = target "System Power Off" early;
      halt = target "System Halt" early;
      kexec = target "Reboot via kexec" early;
      sleep = target "Sleep" early;
      suspend = target "Suspend" early;
      hibernate = target "Hibernate" early;
      hybrid-sleep = target "Hybrid Suspend+Hibernate" early;
      suspend-then-hibernate = target "Suspend; Hibernate if not used for a period of time" early;

      first-boot-complete = target "First Boot Complete" early;
      boot-complete = target "Boot Completion Check" { };
      sigpwr = target "Power Failure" early;
      machines = target "Containers" { };

      # NixOS additions that upstream declares in systemd.nix.
      keys = {
        description = "Security Keys";
        unitConfig.X-StopOnReconfiguration = true;
      };
      sysinit-reactivation.description = "Reactivate sysinit units";
    };

    systemd.services = {
      kmod-static-nodes = lib.recursiveUpdate early {
        description = "Create List of Static Device Nodes";
        wantedBy = [ "sysinit.target" ];
        before = [
          "sysinit.target"
          "systemd-tmpfiles-setup-dev.service"
        ];
        unitConfig.ConditionFileNotEmpty = "/run/booted-system/kernel-modules/lib/modules/%v/modules.devname";
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStartPre = "${pkgs.coreutils}/bin/mkdir -p /run/tmpfiles.d";
          ExecStart = "${pkgs.kmod}/bin/kmod static-nodes --format=tmpfiles --output=/run/tmpfiles.d/static-nodes.conf";
        };
      };

      systemd-modules-load = lib.recursiveUpdate early {
        description = "Load Kernel Modules";
        wantedBy = [ "sysinit.target" ];
        before = [ "sysinit.target" ];
        unitConfig.X-S6-Name = "modules-load";
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = loadModules;
        };
      };

      systemd-sysctl = lib.recursiveUpdate early {
        description = "Apply Kernel Variables";
        wantedBy = [ "sysinit.target" ];
        after = [ "systemd-modules-load.service" ];
        before = [ "sysinit.target" ];
        unitConfig.X-S6-Name = "sysctl";
        restartTriggers = [ config.environment.etc."sysctl.d/60-nixos.conf".source ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = applySysctl;
        };
      };

      systemd-tmpfiles-setup-dev = lib.recursiveUpdate early {
        description = "Create Static Device Nodes in /dev";
        wantedBy = [ "sysinit.target" ];
        before = [
          "sysinit.target"
          "local-fs-pre.target"
          "systemd-udevd.service"
        ];
        unitConfig.X-S6-Name = "tmpfiles-dev";
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = "systemd-tmpfiles --prefix=/dev --create --boot";
          SuccessExitStatus = "DATAERR CANTCREAT";
        };
      };

      systemd-tmpfiles-setup = lib.recursiveUpdate early {
        description = "Create System Files and Directories";
        wantedBy = [ "sysinit.target" ];
        after = [ "local-fs.target" ];
        before = [ "sysinit.target" ];
        unitConfig.X-S6-Name = "tmpfiles-setup";
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = "systemd-tmpfiles --create --remove --boot --exclude-prefix=/dev";
          SuccessExitStatus = "DATAERR CANTCREAT";
        };
      };

      systemd-tmpfiles-clean = lib.recursiveUpdate early {
        description = "Cleanup of Temporary Directories";
        after = [ "local-fs.target" ];
        unitConfig.X-S6-Name = "tmpfiles-clean";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "systemd-tmpfiles --clean";
          SuccessExitStatus = "DATAERR";
          IOSchedulingClass = "idle";
        };
      };

      systemd-random-seed = lib.recursiveUpdate early {
        description = "Load/Save OS Random Seed";
        wantedBy = [ "sysinit.target" ];
        after = [ "local-fs.target" ];
        before = [ "sysinit.target" ];
        unitConfig.X-S6-Name = "random-seed";
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = pkgs.writeShellScript "random-seed-load" ''
            if [ -s ${seedFile} ]; then
              ${pkgs.coreutils}/bin/cat ${seedFile} > /dev/urandom
            fi
            umask 077
            ${pkgs.coreutils}/bin/head -c 512 /dev/urandom > ${seedFile}
          '';
          ExecStop = pkgs.writeShellScript "random-seed-save" ''
            umask 077
            ${pkgs.coreutils}/bin/head -c 512 /dev/urandom > ${seedFile}
          '';
        };
      };

      systemd-vconsole-setup = {
        description = "Virtual Console Setup";
        wantedBy = [ "sysinit.target" ];
        after = [ "systemd-modules-load.service" ];
        before = [ "sysinit.target" ];
        unitConfig = {
          DefaultDependencies = false;
          X-S6-Name = "vconsole-setup";
        };
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = vconsoleSetup;
        };
      };

      systemd-user-sessions = {
        description = "Permit User Sessions";
        wantedBy = [ "multi-user.target" ];
        after = [
          "remote-fs.target"
          "nss-user-lookup.target"
          "network.target"
        ];
        unitConfig.X-S6-Name = "user-sessions";
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = "${pkgs.coreutils}/bin/rm -f /run/nologin";
        };
      };
    };

    systemd.timers.systemd-tmpfiles-clean = {
      description = "Daily Cleanup of Temporary Directories";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "15min";
        OnUnitActiveSec = "1d";
      };
    };

    # Upstream takes this file from the systemd package; the settings below
    # are the ones in it that matter outside of systemd.
    environment.etc."sysctl.d/50-default.conf".text = ''
      kernel.sysrq = 16
      kernel.core_uses_pid = 1
      net.ipv4.conf.default.rp_filter = 2
      net.ipv4.conf.default.accept_source_route = 0
      net.ipv4.conf.default.promote_secondaries = 1
      -net.ipv4.ping_group_range = 0 2147483647
      -net.core.default_qdisc = fq_codel
      fs.protected_hardlinks = 1
      fs.protected_symlinks = 1
      fs.protected_regular = 1
      fs.protected_fifos = 1
    '';

    boot.kernel.sysctl."kernel.pid_max" = lib.mkIf pkgs.stdenv.hostPlatform.is64bit (
      lib.mkDefault 4194304
    );
  };
}
