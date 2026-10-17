# tmpfiles.d.
#
# The options (`systemd.tmpfiles.rules`, `.settings`, `.packages`) are
# upstream's, from system/boot/systemd/tmpfiles.nix; the rules are applied by
# sd-tmpfiles through the systemd-tmpfiles-* units in ../compat/base-units.nix.
#
# Two differences to upstream: the stock rules come from this tree rather
# than from the systemd package, and a package in `systemd.tmpfiles.packages`
# that has no tmpfiles.d directory is skipped instead of failing the build -
# packages built without systemd support often do not install theirs.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.systemd.tmpfiles;

  escapeArgument = lib.strings.escapeC [
    "\t"
    "\n"
    "\r"
    " "
    "\\"
  ];

  settingsEntryToRule = path: entry: ''
    '${entry.type}' '${path}' '${entry.mode}' '${entry.user}' '${entry.group}' '${entry.age}' ${escapeArgument entry.argument}
  '';

  pathsToRules = lib.mapAttrsToList (
    path: types: lib.concatStrings (lib.mapAttrsToList (_type: settingsEntryToRule path) types)
  );

  mkRuleFileContent = paths: lib.concatStrings (pathsToRules paths);

  # The directories every system has, under the file names systemd ships
  # them in.  The names matter: for two lines on one path the file that sorts
  # first wins, and 00-nixos.conf (`systemd.tmpfiles.rules`) must come before
  # these, as it does upstream - e.g. a shorter age for /tmp.
  stockFiles = {
    "home.conf" = ''
      q /home 0755 - - -
      q /srv 0755 - - -
    '';
    "tmp.conf" = ''
      q /tmp 1777 root root 10d
      q /var/tmp 1777 root root 30d
      # (PrivateTmp= of running services: not for cleaning)
      x /tmp/systemd-private-%b-*
      X /tmp/systemd-private-%b-*/tmp
      x /var/tmp/systemd-private-%b-*
      X /var/tmp/systemd-private-%b-*/tmp
    '';
    "var.conf" = ''
      q /var 0755 - - -
      L /var/run - - - - ../run
      d /var/log 0755 - - -
      f /var/log/wtmp 0664 root utmp -
      f /var/log/btmp 0660 root utmp -
      f /var/log/lastlog 0664 root utmp -
      d /var/cache 0755 - - -
      d /var/lib 0755 - - -
      d /var/spool 0755 - - -
      d /var/lib/units 0755 root root -
      d /var/lib/lastlog 0755 root root -
    '';
    "systemd.conf" = ''
      d /run/user 0755 root root -
      F! /run/utmp 0664 root utmp -
      d /run/log 0755 root root -
      F! /run/nologin 0644 - - - "System is booting up. Unprivileged users are not permitted to log in yet."
    '';
    "x11.conf" = ''
      D! /tmp/.X11-unix 1777 root root 10d
      D! /tmp/.ICE-unix 1777 root root 10d
      D! /tmp/.XIM-unix 1777 root root 10d
      D! /tmp/.font-unix 1777 root root 10d
      r! /tmp/.X[0-9]*-lock
    '';
    "static-nodes-permissions.conf" = ''
      z /dev/snd/seq      0660 - audio -
      z /dev/snd/timer    0660 - audio -
      z /dev/loop-control 0660 - disk  -
      z /dev/net/tun      0666 - -     -
      z /dev/fuse         0666 - -     -
      z /dev/vfio/vfio    0666 - -     -
      z /dev/kvm          0666 - kvm   -
      z /dev/vhost-net    0666 - kvm   -
      z /dev/vhost-vsock  0666 - kvm   -
    '';
  };

  stock = pkgs.symlinkJoin {
    name = "stock-tmpfiles.d";
    paths = lib.mapAttrsToList (name: text: pkgs.writeTextDir "lib/tmpfiles.d/${name}" text) stockFiles;
  };
in

{
  config = {
    systemd.services."systemd-tmpfiles-resetup" = {
      description = "Re-setup tmpfiles on a system that is already running.";
      requiredBy = [ "sysinit-reactivation.target" ];
      after = [ "local-fs.target" ];
      before = [ "sysinit-reactivation.target" ];
      restartTriggers = [ config.environment.etc."tmpfiles.d".source ];
      unitConfig = {
        DefaultDependencies = false;
        X-S6-Name = "tmpfiles-resetup";
      };
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "systemd-tmpfiles --create --remove --exclude-prefix=/dev";
        SuccessExitStatus = "DATAERR CANTCREAT";
      };
    };

    environment.etc = {
      "tmpfiles.d".source =
        (pkgs.runCommand "tmpfiles.d"
          {
            packages = map toString cfg.packages;
            preferLocalBuild = true;
            allowSubstitutes = false;
          }
          ''
            mkdir -p $out
            for package in $packages; do
              dir=$package/lib/tmpfiles.d
              if [ ! -d "$dir" ]; then
                echo "note: $package has no tmpfiles.d directory, skipping it"
                continue
              fi
              for file in "$dir"/*.conf; do
                [ -e "$file" ] || continue
                # the first package to provide a name wins
                [ -e "$out/$(basename "$file")" ] || ln -s "$file" "$out/"
              done
            done
            ${lib.concatMapStrings (
              name:
              lib.optionalString (lib.hasPrefix "tmpfiles.d/" name) ''
                rm -f $out/${lib.removePrefix "tmpfiles.d/" name}
              ''
            ) config.system.build.etc.passthru.targets}
          ''
        )
        + "/*";
      "mtab" = {
        mode = "direct-symlink";
        source = "/proc/mounts";
      };
    };

    systemd.tmpfiles.packages = [
      stock
      (pkgs.writeTextFile {
        name = "nixos-tmpfiles.d";
        destination = "/lib/tmpfiles.d/00-nixos.conf";
        text = ''
          # This file is created automatically and should not be modified.
          # Please change the option ‘systemd.tmpfiles.rules’ instead.

          ${lib.concatStringsSep "\n" cfg.rules}
        '';
      })
    ]
    ++ (lib.mapAttrsToList (
      name: paths: pkgs.writeTextDir "lib/tmpfiles.d/${name}.conf" (mkRuleFileContent paths)
    ) cfg.settings);

    systemd.tmpfiles.rules = [
      "d  /run/lock                          0755 root root - -"
      "d  /var/db                            0755 root root - -"
      "L  /var/lock                          -    -    -    - ../run/lock"
      # Boot-time cleanup
      "R! /etc/group.lock                    -    -    -    - -"
      "R! /etc/passwd.lock                   -    -    -    - -"
      "R! /etc/shadow.lock                   -    -    -    - -"
    ];
  };
}
