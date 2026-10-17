# NixOS VM tests against this tree.
#
# The test framework is nixpkgs' own (nixos/lib/testing): same driver, same
# `nodes` / `testScript` interface.  The one thing that has to change is the
# base module list its nodes are built from, which upstream hard-codes; the
# file that does so is patched at evaluation time.
{
  nixpkgs,
  lib,
  # what the nodes do about the systemd that packages bring along, unless a
  # test says otherwise (s6.systemdPackages): "replace" runs on binaries from
  # the cache and is what makes running hundreds of tests affordable
  systemdPackages ? "replace",
  # build the nodes the way a user of an unmodified `nixpkgs.lib.nixosSystem`
  # would: nixpkgs' own list of modules plus modules/default.nix, instead of
  # ./modules/module-list.nix as the base
  moduleMode ? false,
}:

let
  upstream = import "${nixpkgs}/nixos/lib/testing" { inherit lib; };

  modulesDir = toString ../modules;

  replace =
    from: to: text:
    assert lib.assertMsg (lib.hasInfix from text) ''
      lib/testing.nix: expected to find
        ${from}
      in ${nixpkgs}/nixos/lib/testing/nodes.nix.  nixpkgs was probably bumped
      and the test framework has changed; adjust the patch.
    '';
    builtins.replaceStrings [ from ] [ to ] text;

  nodesModule = builtins.toFile "nodes.nix" (
    lib.pipe (builtins.readFile "${nixpkgs}/nixos/lib/testing/nodes.nix") [
      (replace "import ../eval-config.nix" "import ${nixpkgs}/nixos/lib/eval-config.nix")
      (replace "(import ../../modules/module-list.nix)" (
        if moduleMode then
          ''
            (import ${nixpkgs}/nixos/modules/module-list.nix ++ [ ${modulesDir}/default.nix ${modulesDir}/testing.nix ])''
        else
          ''
            (import ${modulesDir}/module-list.nix { inherit lib; nixpkgs = "${nixpkgs}"; } ++ [ ${modulesDir}/testing.nix ])''
      ))
      (replace "./nixos-test-base.nix" "${nixpkgs}/nixos/lib/testing/nixos-test-base.nix")
      (replace "../../modules/" "${nixpkgs}/nixos/modules/")
    ]
  );

  testModules = map (
    m: if lib.hasSuffix "/nodes.nix" (toString m) then nodesModule else m
  ) upstream.testModules;

  # Test files take `pkgs` to mean "packages for the machines" (upstream
  # makes it the host's, which is the same set there).  Here the machines'
  # packages are built without systemd, so a test that puts one of its own
  # `pkgs.foo` into a node must get that variant, or the node would carry
  # systemd after all.  The host side (QEMU, the driver) keeps `hostPkgs`.
  machinePackages =
    { lib, hostPkgs, ... }:
    let
      pkgs = import nixpkgs {
        inherit (hostPkgs.stdenv.hostPlatform) system;
        overlays = [
          (import ../pkgs/overlay.nix)
        ] ++ lib.optional (systemdPackages == "rebuild") (import ../pkgs/no-systemd.nix);
      };
    in
    {
      config._module.args.pkgs = lib.mkForce pkgs;

      # nixpkgs' all-tests.nix hands every test one package set for its nodes
      # (`node.pkgs`) and makes the `nixpkgs.*` options read-only; tests also
      # take their packages from it (`config.node.pkgs.foo`).  The nodes here
      # get theirs through those options (the overlay is a `nixpkgs.overlays`
      # of the system), so the set is the same one, and not read-only.
      config.node.pkgs = lib.mkForce pkgs;
      config.node.pkgsReadOnly = lib.mkForce false;

      # marks what was built here, as opposed to by stock NixOS
      config.passthru.nixithos = true;

      config.defaults.s6.systemdPackages = lib.mkDefault systemdPackages;
      # what failed and why ends up in the test log
      config.defaults.s6.logging.echoFailures = lib.mkDefault true;
    };

  evalTest =
    module:
    lib.evalModules {
      modules = testModules ++ [
        machinePackages
        module
      ];
      class = "nixosTest";
    };

  runTest =
    module:
    (evalTest (
      { config, ... }:
      {
        imports = [ module ];
        result = config.test;
      }
    )).config.result;
in

{
  inherit evalTest runTest;
}
