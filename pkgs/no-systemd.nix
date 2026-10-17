# nixpkgs without systemd.
#
# Most packages in nixpkgs make their systemd support depend on whether
# systemd is available for the platform they are built for
# (`lib.meta.availableOn stdenv.hostPlatform systemd`), which is how the musl
# and static package sets do without it.  Declaring systemd unavailable
# therefore switches all of that off in one go, and `udev` (libudev for
# everybody) no longer comes from systemd.  We point it at eudev.
#
# The `systemd` attribute itself becomes the shim package: NixOS modules that
# name `pkgs.systemd` for one of its tools (systemctl, shutdown,
# systemd-notify, …) get the s6 front-end of the same name.  A package that
# insists on building against systemd finds no library there and fails to
# build, which is the signal to deal with it below.
final: prev:

let
  # Not `overrideAttrs`: the shim must stay usable.  Only what
  # `lib.meta.availableOn` looks at changes.
  unavailable =
    pkg:
    pkg
    // {
      meta = (pkg.meta or { }) // {
        platforms = [ ];
      };
    };

  shim = unavailable final.nixithos.systemdShim;
in

{
  systemd = shim;
  systemdMinimal = shim;
  systemdLibs = shim;
  systemdUkify = shim;

  udev = final.eudev;

  # Test suites that were written against systemd's udev and its idea of the
  # order of sysfs attributes; eudev passes them with other values.
  libgudev = prev.libgudev.overrideAttrs (_: {
    doCheck = false;
  });
}
