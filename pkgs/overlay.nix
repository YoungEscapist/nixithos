# Packages specific to this tree, exposed as `pkgs.nixithos.*`, and the few
# adjustments to nixpkgs packages it needs.
final: prev: {
  # claude-code is a prebuilt binary fetched straight from downloads.claude.ai
  # by version+checksum (see its package.nix): bumping it does not touch
  # nixpkgs' own derivation hashes, so it does not cascade into a rebuild of
  # anything else.  Bump the version/checksum pair here when a newer release
  # comes out; `curl -s https://downloads.claude.ai/claude-code-releases/<ver>/manifest.json`
  # has the per-platform checksums.
  claude-code = prev.claude-code.override {
    manifest = {
      version = "2.1.302";
      platforms."linux-x64".checksum = "60d7eb7f12fbb28a52533fe8be5884097403562aa02dc73991a021c7067e29a5";
    };
  };

  # s6-ftrigrd keeps its listeners in a list.  A one-shot listener whose
  # event came was forgotten by the protocol layer (skalibs' sassserver) but
  # stayed in that list; the next subscription got the same slot and was
  # linked in a second time, so the list became a loop and s6-ftrigrd wrote
  # past its array of descriptors.  With s6-rc 0.7, which keeps one
  # s6-ftrigrd for many waits, it segfaulted in about half of the boots, and
  # what waited on it (s6-svwait, systemctl) saw services as never started.
  # Also, a new listener was put at the head without the old head pointing
  # back at it.  Not upstream yet; here until a release has it.
  # (in the scope of skarnet's packages, so that the ones built on s6 -
  # s6-rc, s6-linux-init - are built on this one)
  skawarePackages = prev.skawarePackages.overrideScope (
    _: sprev: {
      s6 = sprev.s6.overrideAttrs (old: {
        patches = (old.patches or [ ]) ++ [ ./s6/ftrigrd-list.patch ];
      });
    }
  );
  inherit (final.skawarePackages)
    s6
    s6-networking
    s6-rc
    ;

  nixithos = final.lib.makeScope final.newScope (self: {
    # build time: unit files -> s6-rc source
    unitc = self.callPackage ./unitc { };
    # run time: the program each compiled unit runs through, and its helpers
    unitRuntime = self.callPackage ./unit-runtime { };
    unitTools = self.callPackage ./unit-tools { };
    finit = self.callPackage ./finit { };
    finitCtl = self.callPackage ./finit/ctl.nix { };
    # OpenRC, which the init "openrc" runs the machine with
    openrc = self.callPackage ./openrc { };
    # ... and dinitctl's commands put to it
    openrcCtl = self.callPackage ./openrc/ctl.nix { };
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
    # puts a new generation on trial until it has booted, goes back if it did not
    bootAssess = self.callPackage ./boot-assess { };
    # read-only btrfs snapshots before a switch
    snapshots = self.callPackage ./snapshots { };
    # the installer in the console, and nixith-net
    installer = self.callPackage ./nixith-installer { };
  });

  # s6-linux-init-maker gives the catch-all log directory the setgid bit.  The
  # Nix build sandbox refuses to create anything setgid, and the bit only
  # matters when the logger runs as a dedicated user, which it does not here.
  s6-linux-init = final.skawarePackages.s6-linux-init.overrideAttrs (old: {
    postPatch = (old.postPatch or "") + ''
      substituteInPlace src/init/s6-linux-init-maker.c \
        --replace-fail 'UNCAUGHT_DIR, uid, gid, 02750)' 'UNCAUGHT_DIR, uid, gid, 0750)'
    '';
  });

  # kpmcore (KDE Partition Manager's backend) runs lsblk,
  # sfdisk, … only out of its list of trusted prefixes, the store paths of
  # util-linux and the others, compiled in as UTF-16 strings.  Nix sees no
  # reference in those, so the packages need not be in the system at all, and
  # the dependency replacement (no-systemd.nix, mode "replace") does not
  # rewrite them: util-linux, cryptsetup, lvm2 are replaced (they link
  # libsystemd), and kpmcore went on looking for the originals - it found no
  # disk. So the system's profile
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
