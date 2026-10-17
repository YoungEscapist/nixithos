# The nixpkgs revision this tree is developed and tested against.
#
# Everything here is layered on top of an unmodified nixpkgs checkout: upstream
# NixOS modules are imported from it by path, and only the systemd-specific
# ones are swapped out (see ../modules/module-list.nix).  Bumping nixpkgs is
# therefore a matter of changing nixpkgs.json and re-running the tests.
let
  pin = builtins.fromJSON (builtins.readFile ./nixpkgs.json);
in
builtins.fetchTarball {
  name = "source";
  url = "https://github.com/NixOS/nixpkgs/archive/${pin.rev}.tar.gz";
  inherit (pin) sha256;
}
