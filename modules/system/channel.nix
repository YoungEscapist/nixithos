# Makes `<nixpkgs/nixos>` build this kind of system: what nixos-install (under
# `nixith install`), nixos-option and anything else that evaluates it build.
#
# The stock file there builds a NixOS with
# systemd, so `nixpkgs` in NIX_PATH is pointed at a thin tree instead: the
# pinned nixpkgs, with nixos/default.nix swapped for one that evaluates the
# configuration through this tree.  Everything else in it is nixpkgs itself,
# so `import <nixpkgs> { }` and `<nixpkgs/nixos/modules/…>` keep their
# meaning.
#
# (`nixith switch` itself evaluates the configuration through the same tree,
# without NIX_PATH.)  With flakes none of this is involved: `nixith --flake`
# builds whatever `nixithConfigurations.<name>` is, and that is `lib.system`
# of this flake.
{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}:

let
  cfg = config.s6.channel;

  # (the same as nixith's: ./nixith.nix)
  inherit (config.system.build.nixithSources) tree;
  nixpkgsSource = config.system.build.nixithSources.nixpkgs;

  entry = pkgs.writeText "nixos-default.nix" ''
    # <nixpkgs/nixos> for an s6-rc based system; same interface as upstream's.
    {
      configuration ? import ${nixpkgsSource}/nixos/lib/from-env.nix "NIXOS_CONFIG" <nixos-config>,
      system ? builtins.currentSystem,
    }:

    let
      eval = import ${tree}/lib/eval-config.nix {
        nixpkgs = "${nixpkgsSource}";
        inherit system;
        modules = [ configuration ];
      };
    in

    {
      inherit (eval) pkgs config options;

      system = eval.config.system.build.toplevel;

      inherit (eval.config.system.build) vm vmWithBootLoader;
    }
  '';

  channel = pkgs.runCommand "nixithos-channel" { preferLocalBuild = true; } ''
    mkdir -p $out/nixos
    for entry in ${nixpkgsSource}/* ${nixpkgsSource}/.version; do
      [ "$(basename "$entry")" = nixos ] || ln -s "$entry" $out/
    done
    for entry in ${nixpkgsSource}/nixos/*; do
      [ "$(basename "$entry")" = default.nix ] || ln -s "$entry" $out/nixos/
    done
    cp ${entry} $out/nixos/default.nix
    ln -s ${tree} $out/nixithos
  '';
in

{
  options.s6.channel = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = config.nix.enable && !lib.inPureEvalMode;
      defaultText = lib.literalMD "enabled, unless the system is built from a flake";
      description = ''
        Whether to put a `nixpkgs` into `NIX_PATH` whose `nixos` evaluates
        configurations through this tree, so that whatever evaluates
        `<nixpkgs/nixos>` (nixos-install, nixos-option) produces an s6-rc based
        system.  Its sources (the
        pinned nixpkgs and this tree) become part of the system closure.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    system.build.channel = channel;

    nix.nixPath = lib.mkDefault [
      "nixpkgs=${channel}"
      "nixos-config=/etc/nixith/configuration.nix"
    ];
  };
}
