# What the base module list is made of, shared by the two ways of using it:
# ./module-list.nix (as `baseModules` of ../lib/eval-config.nix) and
# ./default.nix (one module to add to an unmodified `nixosSystem`).
#
# Upstream modules fall into three groups:
#
#   kept         imported from nixpkgs untouched.  This is the overwhelming
#                majority (service modules, users, networking, boot loaders…).
#                They keep describing their daemons as `systemd.services.*`;
#                here that option tree is just a data model, which
#                ./compat/units.nix has compiled into an s6-rc database.
#
#   optionsOnly  modules that *are* the systemd integration.  Other modules
#                read and set their options, so the declarations stay, but the
#                `config` half (which installs and drives systemd) is dropped.
#                Where the functionality is needed, a module in this tree
#                provides it (see `ours`).
#
#   dropped      modules this tree replaces completely, options included.
#
# `root` is the directory of the upstream modules (nixpkgs/nixos/modules).
{ root, lib }:

let
  upstream = import "${root}/module-list.nix";
  # The upstream list also has a few inline modules; those have no path.
  rel = p: if lib.isPath p || lib.isString p then lib.removePrefix "${root}/" (toString p) else null;

  optionsOnly = [
    # Unit handling itself                   -> ./compat/units.nix, ./compat/base-units.nix
    "system/boot/systemd.nix"
    # The system closure                     -> ./system/top-level.nix
    "system/activation/top-level.nix"
    # switch-to-configuration                -> ./system/switch.nix
    "system/activation/switchable-system.nix"
    # Stage 2 init                           -> ./system/boot/stage-2.nix
    "system/boot/stage-2.nix"
    # udev                                   -> ./services/udev.nix
    "services/hardware/udev.nix"

    # systemd's own daemons and facilities.  No replacement is implied by
    # being listed here; see docs/status.md for what exists.
    "system/boot/systemd/coredump.nix"
    "system/boot/systemd/dm-verity.nix"
    "system/boot/systemd/fido2.nix"
    "system/boot/systemd/homed.nix"
    "system/boot/systemd/initrd-secrets.nix"
    "system/boot/systemd/initrd.nix"
    "system/boot/systemd/journald-gateway.nix"
    "system/boot/systemd/journald-remote.nix"
    "system/boot/systemd/journald-upload.nix"
    "system/boot/systemd/journald.nix"
    "system/boot/systemd/logind.nix"
    "system/boot/systemd/nspawn.nix"
    "system/boot/systemd/oomd.nix"
    "system/boot/systemd/repart.nix"
    "system/boot/systemd/shutdown.nix"
    "system/boot/systemd/sysupdate.nix"
    "system/boot/systemd/sysusers.nix"
    # tmpfiles.d                              -> ./system/tmpfiles.nix
    "system/boot/systemd/tmpfiles.nix"
    "system/boot/systemd/tpm2.nix"
    "system/boot/systemd/user.nix"
    "system/boot/systemd/userdbd.nix"
    "system/boot/networkd.nix"
    "system/boot/resolved.nix"
    "system/boot/timesyncd.nix"
  ];

  dropped = [
    # Scripted initrd, vendored and adapted   -> ./system/boot/stage-1.nix
    "system/boot/stage-1.nix"
  ];

  # Import an upstream module, keeping its option declarations (and the
  # option renames in `imports`) but none of its configuration.
  mkOptionsOnly =
    relPath:
    let
      file = "${root}/${relPath}";
      f = import file;
      strip = m: {
        options = m.options or { };
        imports = m.imports or [ ];
      };
    in
    lib.setDefaultModuleLocation "${file} (options only)" (
      if lib.isFunction f then lib.setFunctionArgs (args: strip (f args)) (lib.functionArgs f) else strip f
    );

  known = map rel upstream;
  unknown = lib.filter (p: !(lib.elem p known)) (optionsOnly ++ dropped);

  kept = lib.filter (p: !(lib.elem (rel p) (optionsOnly ++ dropped))) upstream;

  # (Not as paths: the documentation of NixOS builds the options of the
  # modules that are paths of a list of modules in a sandbox of their own, from
  # their names relative to nixpkgs' modules, which ours are not.  Modules that
  # are not paths are evaluated with the rest, and their options are in the
  # manual all the same.)
  ours = map (p: lib.setDefaultModuleLocation (toString p) (import p)) [
    ./base.nix
    ./branding.nix
    ./theme.nix
    ./no-systemd.nix
    ./s6
    ./compat/units.nix
    ./compat/base-units.nix
    ./compat/package-units.nix
    ./compat/user-units.nix
    ./system/top-level.nix
    ./system/early.nix
    ./system/switch.nix
    ./system/channel.nix
    ./system/nixith.nix
    ./system/fstab-units.nix
    ./system/tmpfiles.nix
    ./system/boot/stage-1.nix
    ./system/boot/stage-2.nix
    ./services/udev.nix
    ./services/dbus.nix
    ./services/getty.nix
    ./services/elogind.nix
    ./services/user-manager.nix
    ./services/logging.nix
    ./services/timesyncd.nix
    ./services/hostname.nix
    ./desktop/dwl.nix
    ./desktop/desktops.nix
    ./desktop/utilities.nix
  ];
in
assert lib.assertMsg (unknown == [ ]) ''
  modules/parts.nix refers to upstream modules that no longer exist:
    ${lib.concatStringsSep "\n  " unknown}
  nixpkgs was probably bumped; check where they moved.
'';
{
  inherit
    optionsOnly
    dropped
    kept
    mkOptionsOnly
    ours
    ;
}
