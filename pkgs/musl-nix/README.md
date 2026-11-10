# Experimental native Nix candidate

`default.nix` is an experimental, opt-in package (`withNix = true` in the musl
constructor). See `docs/musl-busybox.md` for what has been verified. It expects `crossPkgs`, a
nixpkgs cross-musl package set. Nix 2.28 and Boost use the same LLVM libc++
stdenv; C dependencies use the cross-musl package set. AWS, curl IDN, Public
Suffix List and GSSAPI support, BLAKE3's TBB backend, documentation, OpenSSL's
AF_ALG engine, and the Nix, SQLite, and header-only dependency tests are
disabled. boehm-gc uses the same libc++ stdenv so no GCC runtime is retained. SQLite is built
without its Tcl extension; build-host Tcl remains necessary to generate sources.
These choices are functional limitations. Copying Boost libraries into Nix is
inherited from nixpkgs; the libc++ library path is kept.

Example evaluation on x86_64:

```
let pkgs = import /path/to/pinned/nixpkgs {}; in
import ./pkgs/musl-nix {
  crossPkgs = pkgs.pkgsCross.musl64;
  busyboxSandboxShell = pkgs.callPackage ./pkgs/musl-busybox {};
  enableUnvalidated = true; # development only
}
```

`audit.py OUTPUT --readelf PATH [--reviewed-static FILE]` performs
conservative preliminary checks. Static executables fail unless named with
`--reviewed-static` after a separate provenance review (the Zig-built BusyBox
sandbox shell); relocatable startup objects are ignored. A passing preflight
is not proof that all GNU code or unsupported shell assumptions are absent.
Do not remove store references to make an audit pass. Daemon and multi-user
operation, generation management through Nix, cache.nixos.org downloads and
remote builds have not been exercised on the strict system.
