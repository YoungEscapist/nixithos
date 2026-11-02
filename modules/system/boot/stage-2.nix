# Stage 2 init: the script the initrd executes as PID 1 in the real root.
# Options are upstream's (stage-2.nix is imported options-only); the script is
# ./stage-2-init.sh, which ends by executing the init system: s6-linux-init,
# or dinit (nixithos.init).
{
  config,
  lib,
  pkgs,
  ...
}:

let
  useHostResolvConf = config.networking.resolvconf.enable && config.networking.useHostResolvConf;
  isS6 = config.nixithos.init == "s6";
  # what stage 2 executes in the end: bin/init of either
  initBase = if isS6 then config.system.build.s6InitBase else config.system.build.dinitInit;
in

{
  config = {
    system.build.bootStage2 = pkgs.replaceVarsWith {
      src = ./stage-2-init.sh;
      isExecutable = true;
      replacements = {
        shell = "${pkgs.bash}/bin/bash";
        systemConfig = null; # replaced in ../top-level.nix
        inherit (config.boot) stage2Greeting;
        nixStoreMountOpts = lib.concatStringsSep " " (map lib.escapeShellArg config.boot.nixStoreMountOpts);
        inherit useHostResolvConf;
        inherit (config.system.build) earlyMountScript;
        inherit initBase;
        initName = if isS6 then "s6-linux-init" else "dinit";
        path = lib.makeBinPath (
          [
            pkgs.coreutils
            pkgs.util-linux
          ]
          ++ lib.optional useHostResolvConf pkgs.openresolv
        );
        postBootCommands = pkgs.writeText "local-cmds" ''
          ${config.boot.postBootCommands}
        '';
      };
    };

    # Nothing reads this any more; keep scripts that print it truthful.
    boot.systemdExecutable = lib.mkDefault "${initBase}/bin/init";
  };
}
