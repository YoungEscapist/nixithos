# Experimental Finit backend: native tasks/conditions and supervision.
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
      include /run/units/.db/finit/services.conf
    '';
    environment.systemPackages = [ pkgs.nixithos.finitCtl (pkgs.runCommand "finit-tools" {} ''
      mkdir -p $out/bin
      ln -s ${finit}/sbin/initctl $out/bin/initctl
    '') ];
    warnings = [ "The finit backend is experimental: optional failure propagation and live configuration switches are not validated yet." ];
  };
}
