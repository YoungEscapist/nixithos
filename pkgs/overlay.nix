# Packages specific to this tree, exposed as `pkgs.nixithos.*`, and the few
# adjustments to nixpkgs packages it needs.
final: prev: {
  nixithos = final.lib.makeScope final.newScope (self: {
    # build time: unit files -> s6-rc source
    unitc = self.callPackage ./unitc { };
    # run time: the program each compiled unit runs through, and its helpers
    unitRuntime = self.callPackage ./unit-runtime { };
    unitTools = self.callPackage ./unit-tools { };
    # systemd.link(5) files, applied for eudev
    unitLink = self.callPackage ./unit-link { };
    # the mount namespace of sandboxed units (PrivateTmp=, ProtectSystem=, …)
    unitSandbox = self.callPackage ./unit-sandbox { };
    # tmpfiles.d / sysusers.d without systemd
    sd-tools = self.callPackage ./sd-tools { };
    # stands in for `config.systemd.package`
    systemdShim = self.callPackage ./systemd-shim { };
    # ... and systemd-boot's tools, out of the real package
    systemdBootTool = self.callPackage ./systemd-shim/boot-tool.nix { };
    # ... and `busctl`, `systemd-analyze security`, out of it the same way
    systemdClientTools = self.callPackage ./systemd-shim/client-tools.nix { };
    # one s6 supervision tree per logged-in user
    userManager = self.callPackage ./user-manager { };
    # what `nixos-rebuild switch` runs on the target
    switch-to-configuration = self.callPackage ./switch-to-configuration { };
  });

  # s6-linux-init-maker gives the catch-all log directory the setgid bit.  The
  # Nix build sandbox refuses to create anything setgid, and the bit only
  # matters when the logger runs as a dedicated user, which it does not here.
  s6-linux-init = prev.s6-linux-init.overrideAttrs (old: {
    postPatch = (old.postPatch or "") + ''
      substituteInPlace src/init/s6-linux-init-maker.c \
        --replace-fail 'UNCAUGHT_DIR, uid, gid, 02750)' 'UNCAUGHT_DIR, uid, gid, 0750)'
    '';
  });

  # kpmcore (KDE Partition Manager's and Calamares's backend) runs lsblk,
  # sfdisk, … only out of its list of trusted prefixes, the store paths of
  # util-linux and the others, compiled in as UTF-16 strings.  Nix sees no
  # reference in those, so the packages need not be in the system at all, and
  # the dependency replacement (no-systemd.nix, mode "replace") does not
  # rewrite them: util-linux, cryptsetup, lvm2 are replaced (they link
  # libsystemd), and kpmcore went on looking for the originals - it found no
  # disk, and Calamares had nothing to install on.  So the system's profile
  # is one of the prefixes as well.
  kdePackages = prev.kdePackages.overrideScope (
    kfinal: kprev: {
      kpmcore = kprev.kpmcore.overrideAttrs (old: {
        postPatch = (old.postPatch or "") + ''
          f=src/util/trustedprefixes
          printf '%s\n%s' "$(cat $f)" /run/current-system/sw > $f.new
          mv $f.new $f
        '';
      });
    }
  );
}
