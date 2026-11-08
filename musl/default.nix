# Strict runtime profile: Nix and the build environment run on the build host;
# only independently audited target packages go into this root filesystem.
{
  nixpkgs ? import ../lib/nixpkgs.nix,
  system ? builtins.currentSystem,
  configuration ? { },
  withNix ? false,
}:
let
  hostPkgs = import nixpkgs { inherit system; };
  inherit (hostPkgs) lib;
  busybox = hostPkgs.callPackage ../pkgs/musl-busybox { };
  dinit = hostPkgs.callPackage ../pkgs/musl-dinit { };
  nativeNix = import ../pkgs/musl-nix {
    crossPkgs = if system == "x86_64-linux" then hostPkgs.pkgsCross.musl64
      else import nixpkgs { localSystem = system; crossSystem.config = "aarch64-unknown-linux-musl"; };
    busyboxSandboxShell = busybox;
    enableUnvalidated = true;
  };
  pkgs = hostPkgs.pkgsMusl // { inherit busybox dinit; }
    // lib.optionalAttrs withNix { nix = nativeNix; };
  config = if builtins.isFunction configuration then configuration { inherit pkgs lib; } else configuration;
  console = config.console or (if system == "aarch64-linux" then "ttyAMA0" else "ttyS0");
  userServices = config.services or { };
  services = assert lib.assertMsg (!(userServices ? __console)) "musl: service name __console is reserved";
    userServices // {
      __console = {
        command = [ "/bin/getty" "-L" console "115200" "vt100" ];
        restart = true;
        stopSignal = "HUP";
        stopTimeout = 5;
      };
    };
  runtimePackage = hostPkgs.callPackage ../pkgs/musl-runtime { inherit busybox; };
  runtime = {
    package = runtimePackage;
    services = import ../pkgs/musl-runtime/services.nix {
      inherit lib pkgs;
      runtime = runtimePackage;
      inherit services;
    };
  };
  control = hostPkgs.callPackage ../pkgs/musl-control { inherit busybox dinit; };
  result = import ./system.nix {
    inherit pkgs hostPkgs config runtime control;
    nativeNix = if withNix then nativeNix else null;
  };
in
assert lib.assertMsg (builtins.elem system [ "x86_64-linux" "aarch64-linux" ]) "musl profile supports x86_64-linux and aarch64-linux";
result // { inherit pkgs hostPkgs runtime control; nativeNix = if withNix then nativeNix else null; }
