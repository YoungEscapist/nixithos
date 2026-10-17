# The base module list: upstream NixOS, minus systemd, plus s6.  What goes
# where, and why, is in ./parts.nix.
{ nixpkgs, lib }:

let
  parts = import ./parts.nix {
    root = "${nixpkgs}/nixos/modules";
    inherit lib;
  };
in
parts.kept ++ map parts.mkOptionsOnly parts.optionsOnly ++ parts.ours
