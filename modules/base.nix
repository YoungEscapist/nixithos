# Settings every system built from this tree shares.
{
  config,
  lib,
  pkgs,
  ...
}:

{
  nixpkgs.overlays = lib.mkBefore [ (import ../pkgs/overlay.nix) ];

  # systemctl & co. as front-ends to s6-rc, halt/poweroff/reboot.
  environment.systemPackages = [ config.systemd.package ];

  # The initrd is the scripted one (./system/boot/stage-1.nix).
  boot.initrd.systemd.enable = lib.mkForce false;

  # Options of systemd daemons that do not exist here.  Their modules are
  # imported for the declarations only; these settings make the values other
  # modules read tell the truth.
  services.resolved.enable = lib.mkForce false;
  systemd.oomd.enable = lib.mkForce false;
  systemd.coredump.enable = lib.mkForce false;
  systemd.sysusers.enable = lib.mkForce false;
  system.nixos-init.enable = lib.mkForce false;

  # `networking.useNetworkd` hands the interfaces to systemd-networkd, which
  # is not here.  What `networking.*` describes (addresses, routes, VLANs,
  # bridges…) is set up by the scripted implementation, as with the option
  # off; only hand-written `systemd.network.*` has nothing to act on it.
  networking.useNetworkd = lib.mkForce false;
  warnings = lib.optional config.systemd.network.enable ''
    systemd.network.enable is set, but there is no systemd-networkd on a
    system without systemd: the files in systemd.network.* are written and
    nothing applies them.  The networking.* options work as they do with
    scripted networking.
  '';

  # slurmd asks systemd over D-Bus for a scope to put slurmstepd in, and
  # gives up without one.  With this it makes the scope's cgroup itself,
  # which is what slurm has the setting for.  (IgnoreSystemdOnFailure= would
  # be the gentler one, but slurm 25 dies before it gets to look at it.)
  services.slurm.extraCgroupConfig = lib.mkAfter "IgnoreSystemd=yes";

  # Many services assume a system bus.
  services.dbus.enable = lib.mkDefault true;

  # The manual's options are built in two parts: modules that are files of
  # nixpkgs in a sandbox of their own, the rest with the system.  Some of the
  # former read options that are declared, here, by modules of the latter
  # kind (system.systemBuilderCommands, of top-level.nix kept as options only),
  # and fail there; in one part they are all found.
  documentation.nixos.options.splitBuild = lib.mkDefault false;
}
