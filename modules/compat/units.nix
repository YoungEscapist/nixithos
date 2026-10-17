# The `systemd.*` unit options, without systemd.
#
# Upstream declares these options in nixos/modules/system/boot/systemd.nix; we
# import that file for its declarations only (see ../module-list.nix) and
# provide the implementation here.  Unit text is generated exactly as upstream
# does it, with the same library code, so that every NixOS module that defines
# a service keeps working unchanged.  What differs is the consumer: instead of
# being linked into /etc/systemd/system for systemd to load, the unit
# directory is handed to the unit compiler, which turns it into an s6-rc
# service database at build time.
{
  config,
  lib,
  pkgs,
  utils,
  ...
}:

let
  cfg = config.systemd;

  inherit (utils.systemdUtils.lib)
    generateUnits
    targetToUnit
    serviceToUnit
    socketToUnit
    timerToUnit
    pathToUnit
    mountToUnit
    automountToUnit
    sliceToUnit
    ;

  enabledUnits = removeAttrs cfg.units cfg.suppressedSystemUnits;

  # the package as nixpkgs has it, whatever s6.systemdPackages did to `pkgs`:
  # systemd-boot's installer and `systemd-analyze security` are taken out of
  # it (see boot-tool.nix, client-tools.nix)
  realSystemd =
    (import pkgs.path {
      inherit (pkgs.stdenv.hostPlatform) system;
      inherit (pkgs) config;
    }).systemd;
in

{
  config = {
    # The stand-in package; its tools run units through the same runtime as
    # the system's services.
    systemd.package = lib.mkDefault (
      pkgs.nixithos.systemdShim.override {
        nixithos = pkgs.nixithos // {
          unitRuntime = config.system.build.unitRuntime;
        };
        elogind = if config.services.elogind.enable then config.services.elogind.package else null;
        # The boot loader is not the init system: systemd-boot's installer and
        # EFI programs come out of systemd's package as they are, with only
        # the path they refer to themselves by changed (see boot-tool.nix).
        bootTool =
          if config.boot.loader.systemd-boot.enable or false then
            pkgs.nixithos.systemdBootTool.override { systemd = realSystemd; }
          else
            null;
        # `busctl`, and `systemd-analyze security` (systemd's own scoring of a
        # unit file): client programs, out of the package as they are
        clientTools = pkgs.nixithos.systemdClientTools.override { systemd = realSystemd; };
      }
    );

    system.build.units = cfg.units;

    systemd.units =
      let
        withName = cfgToUnit: cfg: lib.nameValuePair cfg.name (cfgToUnit cfg);
      in
      lib.mapAttrs' (_: withName pathToUnit) cfg.paths
      // lib.mapAttrs' (_: withName serviceToUnit) cfg.services
      // lib.mapAttrs' (_: withName sliceToUnit) cfg.slices
      // lib.mapAttrs' (_: withName socketToUnit) cfg.sockets
      // lib.mapAttrs' (_: withName targetToUnit) cfg.targets
      // lib.mapAttrs' (_: withName timerToUnit) cfg.timers
      // lib.listToAttrs (map (withName mountToUnit) cfg.mounts)
      // lib.listToAttrs (map (withName automountToUnit) cfg.automounts);

    # Generate timer units for all services that have a ‘startAt’ value.
    systemd.timers = lib.mapAttrs (name: service: {
      wantedBy = [ "timers.target" ];
      timerConfig.OnCalendar = service.startAt;
    }) (lib.filterAttrs (name: service: service.enable && service.startAt != [ ]) cfg.services);

    # The complete unit directory: units defined through the module system,
    # units shipped by `systemd.packages`, drop-ins, aliases and the
    # .wants/.requires links.  Nothing is copied from a systemd package.
    system.build.systemUnits = generateUnits {
      type = "system";
      units = enabledUnits;
      upstreamUnits = [ ];
      upstreamWants = [ ];
    };

    # Where NixOS has them.  Nothing here reads them (the compiled database
    # has what is needed); they are for people, `systemctl cat`, and tests
    # and tools that look at what a unit was generated as.
    environment.etc."systemd/system".source = config.system.build.systemUnits;
  };
}
