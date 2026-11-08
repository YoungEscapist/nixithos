# Experimental native Nix candidate

`default.nix` is an **unvalidated build candidate**, not a supported system
package. It is not connected to the musl system. It expects `crossPkgs`, a
nixpkgs cross-musl package set. Nix 2.28 and Boost use the same LLVM libc++
stdenv; C dependencies use the cross-musl package set. AWS, curl IDN, Public
Suffix List and GSSAPI support, BLAKE3's TBB backend, documentation, and the
Nix, SQLite, and header-only dependency tests are disabled. SQLite is built
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

Before using this candidate, build it and audit the complete runtime closure,
including interpreters, actual ELF dependencies, copied libraries, scripts,
static executables and package provenance. `audit.py OUTPUT --readelf PATH`
performs conservative preliminary checks and fails on static ELFs requiring
independent review. A passing preflight is not proof that all GNU code or
unsupported shell assumptions are absent. Do not remove store references to
make an audit pass. Exercise local store operations, daemon and generation
management, binary-cache downloads with TLS, and remote build behavior on the
actual strict system before enabling native Nix. Those tests have not yet been
completed.
