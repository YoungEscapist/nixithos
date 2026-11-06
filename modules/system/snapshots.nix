# Snapshots: with the root (and /home) on btrfs subvolumes, switching to a new
# configuration takes a read-only snapshot of them first, and the newest few
# are kept.  Plain `btrfs subvolume snapshot -r`, no snapper; the tool is
# pkgs/snapshots, `nixith snapshots` lists and deletes them.
#
# The installer lays btrfs out as @ (/), @home, @nix, @log (/var/log) and
# @snapshots (/.snapshots), and turns this on.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.nixithos.snapshots;

  tool = pkgs.nixithos.snapshots.override {
    inherit (cfg) keep paths;
    dir = cfg.directory;
  };
in

{
  options.nixithos.snapshots = {
    enable = lib.mkEnableOption "read-only btrfs snapshots of the root and /home before every `switch-to-configuration switch` and `boot` (`nixith snapshots` lists them)";

    keep = lib.mkOption {
      type = lib.types.ints.positive;
      default = 10;
      description = "How many snapshots are kept; the oldest go first.";
    };

    directory = lib.mkOption {
      type = lib.types.strMatching "/.*";
      default = "/.snapshots";
      description = "Where the snapshots are put: on the btrfs file system of the root (the installer mounts the subvolume @snapshots here).";
    };

    paths = lib.mkOption {
      type = lib.types.listOf (lib.types.strMatching "/.*");
      default = [
        "/"
        "/home"
      ];
      description = "The subvolumes that are snapshotted, by where they are mounted.  A path that is not a btrfs subvolume is skipped.";
    };

    hook = lib.mkOption {
      type = lib.types.str;
      internal = true;
      readOnly = true;
      description = "What switch-to-configuration runs before it switches, or an empty string.";
    };
  };

  config = lib.mkMerge [
    {
      nixithos.snapshots.hook = if cfg.enable then "${tool}/bin/nixith-snapshots" else "";
    }

    (lib.mkIf cfg.enable {
      assertions = [ {
        assertion = builtins.length cfg.paths == builtins.length (lib.unique
          (map (p: if p == "/" then "root" else builtins.replaceStrings [ "/" ] [ "-" ] (lib.removePrefix "/" p)) cfg.paths));
        message = "nixithos.snapshots.paths must have distinct snapshot names.";
      } ];
      environment.systemPackages = [ tool ];
      system.build.snapshots = tool;
    })
  ];
}
