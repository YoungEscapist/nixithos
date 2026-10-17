# Builds the system closure (`system.build.toplevel`).
#
# Option declarations come from upstream's top-level.nix (imported options-only
# in ../module-list.nix); this is the builder.  The layout matches NixOS so
# that boot loaders, bootspec and nixos-rebuild find what they expect:
#
#   init                      stage 2, run as PID 1 by the initrd
#   activate, dry-activate    activation script
#   etc, sw, kernel, initrd…  as on NixOS
#   s6                        init base directory, s6-rc database and unit data
#   systemd                   -> the shim package (for /run/current-system/systemd)
{
  config,
  lib,
  pkgs,
  ...
}:

let
  systemBuilder = ''
    mkdir $out

    cp ${config.system.build.bootStage2} $out/init
    substituteInPlace $out/init --subst-var-by systemConfig $out

    ln -s ${config.system.build.etc}/etc $out/etc
    ln -s ${config.system.path} $out/sw
    ln -s "$systemd" $out/systemd

    echo -n "s6-rc ${toString config.systemd.package.interfaceVersion}" > $out/init-interface-version
    echo -n "$nixosLabel" > $out/nixos-version
    echo -n "${config.boot.kernelPackages.stdenv.hostPlatform.system}" > $out/system

    ${config.system.systemBuilderCommands}

    printf "%s " "''${extraDependencies[@]}" > "$out/extra-dependencies"

    ${lib.optionalString (!config.boot.isContainer && config.boot.bootspec.enable) ''
      ${config.boot.bootspec.writer}
      ${lib.optionalString config.boot.bootspec.enableValidation ''${config.boot.bootspec.validator} "$out/${config.boot.bootspec.filename}"''}
    ''}
  '';

  baseSystem = pkgs.stdenvNoCC.mkDerivation (
    {
      name = "nixith-system-${config.system.name}-${config.system.nixos.label}";
      preferLocalBuild = true;
      allowSubstitutes = false;
      buildCommand = systemBuilder;

      systemd = config.systemd.package;

      nixosLabel = config.system.nixos.label;

      inherit (config.system) extraDependencies;
    }
    // config.system.systemBuilderArgs
    // {
      __structuredAttrs = true;
    }
  );

  baseSystemAssertWarn = lib.asserts.checkAssertWarn config.assertions config.warnings baseSystem;

  inherit (config.system.replaceDependencies) replacements cutoffPackages;

  # A check is a function from a system to a derivation whose output is empty
  # when everything is fine and says what is wrong otherwise.  The text is
  # read at evaluation time, so a failure stops `nixos-rebuild` before it
  # installs anything, with that text as the error.
  verdicts =
    checks: drv: lib.concatStrings (map (check: builtins.readFile (check drv)) checks);

  # Only what there is to replace: replaceDependencies warns about each
  # replacement whose original the system does not depend on (dev outputs,
  # the 32-bit libraries of a system without 32-bit programs).
  relevantReplacements =
    let
      closure = pkgs.closureInfo { rootPaths = [ baseSystemAssertWarn ]; };
      paths = lib.splitString "\n" (builtins.readFile "${closure}/store-paths");
    in
    builtins.filter (r: builtins.elem (toString r.oldDependency) paths) replacements;

  replaced =
    if relevantReplacements == [ ] then
      baseSystemAssertWarn
    else
      (pkgs.replaceDependencies.override {
        replaceDirectDependencies = pkgs.callPackage ../../pkgs/replace-direct-dependencies.nix {
          # (the build uses nix-store; a system without Nix - nix.enable =
          # false, pkgs.nix taken away, as in the without-nix test - still
          # gets one, from nixpkgs without the system's overlays)
          nix =
            if config.nix.enable then
              config.nix.package
            else
              (import pkgs.path { inherit (pkgs.stdenv.buildPlatform) system; }).nix;
        };
      })
        {
          drv = baseSystemAssertWarn;
          replacements = relevantReplacements;
          inherit cutoffPackages;
        };

  system =
    if replacements == [ ] then
      baseSystemAssertWarn
    else
      let
        before = verdicts config.system.replaceDependencies.preChecks baseSystemAssertWarn;
        after = verdicts config.system.replaceDependencies.postChecks replaced;
      in
      if before != "" then
        throw "the dependency replacement cannot be applied to this system:\n${before}"
      else if after != "" then
        throw "the system with replaced dependencies is not what was asked for:\n${after}"
      else
        replaced;

  systemWithBuildDeps = system.overrideAttrs (o: {
    systemBuildClosure = pkgs.closureInfo { rootPaths = [ system.drvPath ]; };
    buildCommand = o.buildCommand + ''
      ln -sn $systemBuildClosure $out/build-closure
    '';
  });
in

{
  options.system.replaceDependencies = {
    preChecks = lib.mkOption {
      type = lib.types.listOf lib.types.unspecified;
      default = [ ];
      internal = true;
      description = ''
        Checks (see above) run on the system as it is before the replacements
        are applied.
      '';
    };

    postChecks = lib.mkOption {
      type = lib.types.listOf lib.types.unspecified;
      default = [ ];
      internal = true;
      description = ''
        Checks run on the system after the replacements have been applied.
        This is where `system.forbiddenDependenciesRegexes` is enforced when
        there are replacements, because only then the closure that counts
        is the replaced one.
      '';
    };
  };

  config = {
    system.systemBuilderCommands = lib.optionalString (replacements == [ ] && config.system.forbiddenDependenciesRegexes != [ ]) (
      lib.concatStringsSep "\n" (
        map (regex: ''
          if [[ -n $closureInfo ]]; then
            if forbiddenPaths="$(grep -E -- ${lib.escapeShellArg regex} $closureInfo/store-paths)"; then
              echo -e "System closure $out contains the following disallowed paths:\n$forbiddenPaths"
              exit 1
            fi
          fi
        '') config.system.forbiddenDependenciesRegexes
      )
    );

    system.systemBuilderArgs = {
      # Not used by the builder; listing the checks makes them build
      # dependencies of the system without adding them to its closure.
      passedChecks = lib.concatStringsSep " " config.system.checks;
    }
    // lib.optionalAttrs (config.i18n.glibcLocales != null) {
      localeArchive = "${config.i18n.glibcLocales}/lib/locale/locale-archive";
    }
    // lib.optionalAttrs (replacements == [ ] && config.system.forbiddenDependenciesRegexes != [ ]) {
      closureInfo = pkgs.closureInfo {
        rootPaths = [
          # Overridden to avoid infinite recursion, and to let
          # extraDependencies add otherwise forbidden paths.
          (config.system.build.toplevel.overrideAttrs (_: {
            extraDependencies = [ ];
            closureInfo = null;
          }))
        ];
      };
    };

    system.build.toplevel =
      if config.system.includeBuildDependencies then systemWithBuildDeps else system;

    # The system as it is before s6.systemdPackages = "replace" does its
    # work: what to look at when a check of the replaced closure fails.
    system.build.toplevelUnreplaced = baseSystemAssertWarn;
    # ... and after, without the checks: `nix why-depends` on it shows what
    # still holds on to systemd when they fail
    system.build.toplevelReplacedUnchecked = replaced;
  };
}
