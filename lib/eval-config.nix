# Evaluate a system configuration.
#
# This is the counterpart of nixpkgs' nixos/lib/eval-config.nix (and of
# `lib.nixosSystem`): same arguments, same result shape, but the base module
# list is ours, i.e. upstream NixOS with the systemd layer replaced by s6-rc.
{
  nixpkgs ? import ./nixpkgs.nix,
  system ? builtins.currentSystem,
  modules ? [ ],
  specialArgs ? { },
  extraModules ? [ ],
  lib ? import "${nixpkgs}/lib",
  modulesLocation ? null,
}:

import "${nixpkgs}/nixos/lib/eval-config.nix" (
  {
    inherit
      system
      lib
      specialArgs
      extraModules
      modules
      ;
    baseModules = import ../modules/module-list.nix { inherit nixpkgs lib; };
  }
  // lib.optionalAttrs (modulesLocation != null) { inherit modulesLocation; }
)
