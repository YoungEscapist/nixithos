# A nixpkgs revision, from a file that names it:
#
#   { "branch": "nixos-26.05", "rev": "…", "sha256": "sha256-…" }
#
# ./nixpkgs.json is the release this tree is developed and tested against,
# ./nixpkgs-unstable.json the revision of nixos-unstable it is also tested
# with.  A system follows one of them, or any other, by having such a file
# next to its configuration (/etc/nixith/nixpkgs.json; `nixith channel`
# writes it).
file:

let
  pin = builtins.fromJSON (builtins.readFile file);
in
builtins.fetchTarball {
  name = "source";
  url = "https://github.com/NixOS/nixpkgs/archive/${pin.rev}.tar.gz";
  inherit (pin) sha256;
}
