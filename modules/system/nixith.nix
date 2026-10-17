# `nixith`: the system's tool for building itself, in place of nixos-rebuild
# and the other nixos-* tools (../../pkgs/nixith).
#
#   sudo nixith switch                         the whole configuration
#   sudo nixith switch --only services.nginx   only that part of it
#
# The configuration lives in /etc/nixith.  A system that still has it in
# /etc/nixos (installed before the rename) gets it moved there on activation,
# with /etc/nixos left as a link to it.
{
  config,
  lib,
  pkgs,
  options,
  modulesPath,
  ...
}:

let
  cfg = config.nixith;

  inherit (config.system.build) nixithSources;

  nixith = pkgs.callPackage ../../pkgs/nixith {
    inherit (nixithSources) tree nixpkgs;
    nix = config.nix.package;
    nixos-install = config.system.build.nixos-install;
    nixos-generate-config = config.system.build.nixos-generate-config;
    nixos-option = pkgs.nixos-option.override { nix = config.nix.package; };
  };

  # What `nixith generate-config` writes: nixpkgs' configuration.nix, in
  # NixithOS's words.
  configurationTemplate =
    builtins.replaceStrings
      [
        "nixos-rebuild switch"
        "nixos-rebuild"
        "(`nixos-help`)"
        "networking.hostName = \"nixos\""
        "NixOS"
      ]
      [
        "nixith switch"
        "nixith"
        "(`nixos-help`, as NixithOS is NixOS without systemd)"
        "networking.hostName = \"nixith\""
        "NixithOS"
      ]
      options.system.nixos-generate-config.configuration.default;

  # /etc/nixos (a system installed before the rename) -> /etc/nixith
  moveConfig = ''
    if [ -d /etc/nixos ] && [ ! -L /etc/nixos ] && [ ! -e /etc/nixith ]; then
      mv /etc/nixos /etc/nixith
      ln -s nixith /etc/nixos
    fi
    install -m 0755 -d /etc/nixith
  '';
in
{
  options.nixith.enable = lib.mkOption {
    type = lib.types.bool;
    default = config.nix.enable;
    defaultText = lib.literalExpression "config.nix.enable";
    description = ''
      Whether to install `nixith`, which builds and switches the system
      (`nixith switch`, also only parts of it: `nixith switch --only
      services.nginx`) and installs, enters and describes systems (`nixith
      install`, `nixith generate-config`, ...), in place of nixos-rebuild,
      nixos-install and the other nixos-* tools.
    '';
  };

  config = lib.mkMerge [
    {
      # the tree and the nixpkgs under it, which nixith evaluates systems with
      system.build.nixithSources = {
        tree = builtins.path {
          name = "nixithos";
          path = ../..;
          filter =
            path: type:
            let
              base = baseNameOf path;
            in
            !(base == ".git" || lib.hasPrefix "result" base);
        };
        nixpkgs =
          if lib.inPureEvalMode then
            pkgs.path
          else
            builtins.storePath (/. + (lib.removeSuffix "/nixos/modules" modulesPath));
      };
    }

    (lib.mkIf cfg.enable {
      environment.systemPackages = [ nixith ];
      system.build.nixith = nixith;

      # nixith in their place (it runs them itself)
      system.tools = lib.genAttrs [
        "nixos-build-vms"
        "nixos-enter"
        "nixos-generate-config"
        "nixos-install"
        "nixos-option"
        "nixos-rebuild"
        "nixos-version"
      ] (_: { enable = lib.mkDefault false; });

      system.nixos-generate-config.configuration = lib.mkDefault configurationTemplate;

      system.activationScripts.nixith-config = lib.stringAfter [ "etc" ] moveConfig;
    })
  ];
}
