# Finit as init and service manager (nixithos.init = "finit").
#
#   PID 1          Finit, which stage 2 hands over to through `init` below
#   services       the stanzas unitc writes from the system's units
#                  (finit/services.conf in the unit database), included by
#                  /etc/finit.conf through /run/units/.db, the database of
#                  the configuration that runs; a switch points the link at
#                  another one and has Finit read it again (finitctl rescan)
#   control        finitctl, which answers for Finit what dinitctl is asked
#                  by systemctl, the runtime and switch-to-configuration
#   shutdown       `systemctl poweroff` and friends go to `initctl`; Finit
#                  stops the services and runs s6.init.finalCommands
#
# Per-user managers remain s6; no native getty/hotplug plugins are used.
{ config, lib, pkgs, ... }:
let
  cfg = config.s6.init;
  db = config.system.build.s6Database;
  finit = pkgs.nixithos.finit;
  tools = pkgs.nixithos.unitTools;
  limits = import ../init-limits.nix { inherit lib; } cfg.limits;
  environment = [ "PATH=${lib.makeBinPath [ finit pkgs.coreutils pkgs.util-linux tools ]}:${cfg.path}" ]
    ++ lib.mapAttrsToList (n: v: "${n}=${v}") cfg.environment;
  init = pkgs.writeScriptBin "init" ''
    #!${pkgs.runtimeShell}
    PATH=${lib.makeBinPath [ pkgs.coreutils ]}
    ${limits}
    mkdir -p /run/units/finit.d /run/uncaught-logs
    ln -sfn ${db} /run/units/.db
    ln -sfn ${db} /nix/var/nix/gcroots/units-live
    : > /run/units/.booting
    exec env -i ${lib.concatMapStringsSep " " lib.escapeShellArg environment} \
      ${finit}/sbin/finit
  '';
  final = pkgs.writeShellScript "finit-final" cfg.finalCommands;
in {
  config = lib.mkIf (config.nixithos.init == "finit") {
    system.build.finitInit = init;
    environment.etc."finit.fstab".text = "# Stage 2 and unit-runtime manage mounts.\n";
    environment.etc."finit.conf".text = ''
      set PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.util-linux ]}:${cfg.path}
      runlevel 2
      readiness none
      rcsd /run/units/finit.d
      shutdown ${final}
      # Ctrl-Alt-Del reboots, as under systemd and the other init systems
      # (Finit itself only asserts the condition)
      task [12345] <!sys/key/ctrlaltdel> name:ctrlaltdel ${finit}/sbin/initctl reboot
      include /run/units/.db/finit/services.conf
    '';
    environment.systemPackages = [ pkgs.nixithos.finitCtl (pkgs.runCommand "finit-tools" {} ''
      mkdir -p $out/bin
      ln -s ${finit}/sbin/initctl $out/bin/initctl
    '') ];
  };
}
