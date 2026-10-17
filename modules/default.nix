# The whole of this tree as one module, for use with an unmodified nixpkgs:
#
#   nixpkgs.lib.nixosSystem {
#     modules = [ nixithos.nixosModules.default ./configuration.nix ];
#   };
#
# `nixosSystem` builds on nixpkgs' own list of modules.  The ones that are the
# systemd integration are switched off with `disabledModules` here, and come
# back as the declarations of their options alone (the options other modules
# read and set), next to the modules of this tree that do their work.  The
# result is the module list of ./module-list.nix, as a module.
{ lib, modulesPath, ... }:

let
  parts = import ./parts.nix {
    root = toString modulesPath;
    inherit lib;
  };
in
{
  disabledModules = parts.optionsOnly ++ parts.dropped;
  imports = map parts.mkOptionsOnly parts.optionsOnly ++ parts.ours;
}
