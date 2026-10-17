# Non-flake entry point.
#
#   nix-build -A tests.<name>                  run a VM test (boot, units, switch, login)
#   nix-build -A configs.<name>.toplevel       build one of the sample systems
#   nix-build -A configs.<name>.vm             …or a script that boots it in QEMU
#
# To evaluate your own configuration:
#
#   (import ./. { }).eval { modules = [ ./configuration.nix ]; }
{
  nixpkgs ? import ./lib/nixpkgs.nix,
  system ? builtins.currentSystem,
  # Any other string makes every test a different derivation: to run one that
  # has passed again (`--argstr salt 2`), e.g. to see whether it is flaky.
  salt ? "",
}:

let
  lib = import "${nixpkgs}/lib";

  eval =
    args:
    import ./lib/eval-config.nix (
      {
        inherit nixpkgs system lib;
      }
      // args
    );

  sample =
    file:
    let
      sys = eval { modules = [ file ]; };
    in
    sys.config.system.build // { inherit (sys) config options pkgs; };

  hostPkgs = import nixpkgs { inherit system; };

  # A function from a test (a module, or a file with one in it) to the
  # derivation that runs it.  `systemdPackages` is what the nodes do about
  # the systemd in packages, unless the test says otherwise.
  runnerFor =
    systemdPackages:
    {
      moduleMode ? false,
    }:
    let
      testing = import ./lib/testing.nix { inherit nixpkgs lib systemdPackages moduleMode; };
    in
    file:
    testing.runTest {
      imports = [ file ];
      inherit hostPkgs;
      defaults = lib.mkIf (salt != "") { environment.etc."test-salt".text = salt; };
    };

  # the default mode of the system: packages from the cache, two libraries
  # swapped under them
  runTest = runnerFor "replace" { };

  # ... the same, with the nodes built from nixpkgs' own list of modules and
  # modules/default.nix (`nixosModules.default`), as `nixosSystem` would
  runModule = runnerFor "replace" { moduleMode = true; };

  # ... and the other mode, which compiles the packages without systemd
  runRebuild = runnerFor "rebuild" { };

  # nixpkgs with `nixos/lib/testing-python.nix` replaced.  Every test of
  # nixos/tests/all-tests.nix goes through it: `runTest` there is its
  # `evalTest`, old-style tests (make-test-python.nix) are its `makeTest`.
  # The replacement builds the machines from this tree instead of the stock
  # module list, on binaries from the cache (s6.systemdPackages = "replace"),
  # which is what the tests are written for.  The tests themselves are
  # copies, so that their relative imports find it; all else is linked.
  upstreamTree =
    let
      adapter = builtins.toFile "testing-python.nix" ''
        args@{
          system,
          pkgs ? import ../.. { inherit system; },
          minimal ? false,
          config ? { },
          specialArgs ? null,
          extraConfigurations ? [ ],
        }:
        let
          lib = pkgs.lib;
          testing = import ${toString ./lib/testing.nix} {
            nixpkgs = ${toString nixpkgs};
            inherit lib;
            systemdPackages = "replace";
          };
          extraTestModule = {
            config.hostPkgs = pkgs;
            ${lib.optionalString (salt != "") ''
              config.defaults.environment.etc."test-salt".text = ${builtins.toJSON salt};
            ''}
          };
          evalTest = module: testing.evalTest {
            imports = [ extraTestModule module ];
          };
        in
        rec {
          inherit pkgs evalTest;

          runTest = module: testing.runTest {
            imports = [ extraTestModule module ];
          };

          makeTest = t:
            let
              testConfig = (evalTest {
                imports = [
                  { _file = "makeTest parameters"; config = t; }
                  { defaults = { imports = extraConfigurations; }; }
                ];
              }).config;
            in
            testConfig.test // testConfig;

          simpleTest = as: (makeTest as).test;
        }
      '';
    in
    hostPkgs.runCommand "nixpkgs-for-tests" { preferLocalBuild = true; } ''
      mkdir -p $out/nixos/lib
      for f in ${nixpkgs}/*; do
        n=$(basename "$f")
        [ "$n" = nixos ] || ln -s "$f" "$out/$n"
      done
      for f in ${nixpkgs}/nixos/*; do
        n=$(basename "$f")
        case $n in tests|lib) ;; *) ln -s "$f" "$out/nixos/$n" ;; esac
      done
      for f in ${nixpkgs}/nixos/lib/*; do
        ln -s "$f" "$out/nixos/lib/$(basename "$f")"
      done
      rm $out/nixos/lib/testing-python.nix
      cp ${adapter} $out/nixos/lib/testing-python.nix
      cp -r ${nixpkgs}/nixos/tests $out/nixos/tests
      chmod -R u+w $out/nixos/tests
    '';

in
{
  inherit eval nixpkgs lib;

  # The test suite: all of these pass.
  tests = lib.mapAttrs (_: runTest) {
    boot = ./tests/boot.nix;
    units = ./tests/units.nix;
    switch = ./tests/switch.nix;
    login = ./tests/login.nix;
    # what the default mode does to the closure
    replace = ./tests/replace.nix;
    elogind = ./tests/elogind.nix;
    user-services = ./tests/user-services.nix;
    sandbox = ./tests/sandbox.nix;
    timesync = ./tests/timesync.nix;
    # an installed system: GRUB (BIOS) and Limine (UEFI) start s6 and reboot
    bootloader = ./tests/bootloader.nix;
  }
  // {
    # the same boot and units, with the nodes built from nixpkgs' unmodified
    # module list plus `nixosModules.default`
    module = runModule ./tests/boot.nix;
    module-units = runModule ./tests/units.nix;
    # s6.systemdPackages = "rebuild": the same boot, with the packages compiled
    # without systemd (hours on a desktop, so not part of a quick run)
    rebuild = runRebuild ./tests/boot.nix;
  };

  # A scratch test for poking at a VM; not part of the suite.
  wip = lib.mapAttrs (_: runTest) {
    debug = ./tests/debug.nix;
  };

  # nixpkgs' own NixOS tests, as `nixosTests` has them (all-tests.nix, with
  # the arguments it gives each), run against this tree (see upstreamTree):
  #
  #   nix-build -A upstream.openssh
  #   nix-build -A upstream.postgresql.postgresql   (a group of tests)
  #   nix-build -A upstream.networking.scripted.static
  #
  # The few entries there that do not come through testing-python.nix (a
  # package's own tests, checks of an evaluated configuration) would test
  # stock NixOS; they are refused.  Most of the tests assume systemd in
  # places; what they find is what is left to do.
  upstream =
    let
      all = import "${upstreamTree}/nixos/tests/all-tests.nix" {
        inherit system;
        pkgs = hostPkgs;
        callTest = config: config.test;
      };
      ours =
        path: t:
        if lib.isDerivation t && !(t.nixithos or false) then
          throw "upstream.${lib.concatStringsSep "." path} is not built through this tree"
        else
          t;
    in
    lib.mapAttrsRecursiveCond (t: !lib.isDerivation t) ours all;

  # the installation/live ISO (images/iso.nix)
  iso = (eval { modules = [ ./images/iso.nix ]; }).config.system.build.isoImage;
  # …and with the desktops and the graphical installer (images/iso-graphical.nix)
  isoGraphical = (eval { modules = [ ./images/iso-graphical.nix ]; }).config.system.build.isoImage;

  configs = lib.mapAttrs (_: sample) {
    minimal = ./tests/configs/minimal.nix;
    vm = ./tests/configs/vm.nix;
    cached = ./tests/configs/cached.nix;
    replaced = ./tests/configs/replaced.nix;
    desktops = ./tests/configs/desktops.nix;
  };
}
