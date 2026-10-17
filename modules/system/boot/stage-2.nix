# Stage 2 init: the script the initrd executes as PID 1 in the real root.
# Options are upstream's (stage-2.nix is imported options-only); the script is
# ./stage-2-init.sh, which ends by executing s6-linux-init.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  useHostResolvConf = config.networking.resolvconf.enable && config.networking.useHostResolvConf;
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
        initBase = config.system.build.s6InitBase;
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
    boot.systemdExecutable = lib.mkDefault "${config.system.build.s6InitBase}/bin/init";
  };
}
