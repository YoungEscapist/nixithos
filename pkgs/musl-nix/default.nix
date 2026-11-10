# EXPERIMENTAL opt-in (musl withNix = true); verified scope is in docs/musl-busybox.md.
# Pass a cross-musl package set; its C++ dependencies must use the same libc++ ABI.
{ crossPkgs, busyboxSandboxShell, enableUnvalidated ? false }:
let
  # The AF_ALG engine test binds an skcipher socket and fails whenever the
  # build host cannot autoload algif_skcipher inside the sandbox. Nix never
  # uses that engine, so leave it out instead of skipping the whole suite.
  p = crossPkgs.extend (final: prev: {
    # Overlays reach every bootstrap stage; leave build-host OpenSSL cached.
    openssl = if !prev.stdenv.hostPlatform.isMusl then prev.openssl else
      prev.openssl.overrideAttrs (old: {
        configureFlags = old.configureFlags ++ [ "no-afalgeng" ];
      });
  });
  # The useLLVM platform selects compiler-rt and LLVM unwinding; plain
  # libcxxStdenv retains libgcc_s and GNU libatomic in its runtime closure.
  s = p.pkgsLLVM.stdenv;
  boost = (p.boost.override {
    stdenv = s;
    enableIcu = false;
    extraB2Args = [ "--with-context" "--with-thread" "--with-system" ];
  }).overrideAttrs (old: {
    # b2 forbids mixing --with-* and --without-* selectors.
    buildPhase = builtins.replaceStrings [ "--without-python" ] [ "" ] old.buildPhase;
    installPhase = builtins.replaceStrings [ "--without-python" ] [ "" ] old.installPhase;
  });
  curl = p.curlMinimal.override {
    gssSupport = false;
    idnSupport = false;
    pslSupport = false;
  };
  blake3 = p.libblake3.override { useTBB = false; };
  sqlite = p.sqlite.overrideAttrs (old: {
    doCheck = false;
    # Native Tcl still generates SQLite sources; no target Tcl extension is
    # needed by Nix. Avoid pulling target Tcl and tzdata into the build.
    configureFlags = map (flag:
      if p.lib.hasPrefix "--with-tcl=" flag then "--disable-tcl" else flag
    ) old.configureFlags
      # Without a SONAME the linker records the absolute library path in
      # DT_NEEDED, which the strict closure audit cannot resolve by name.
      ++ [ "--soname=legacy" ];
  });
  # The GCC-built collector ships libgccpp linked against libstdc++, which
  # drags the GCC runtime into the closure; build it with the libc++ stdenv.
  boehmgc = p.boehmgc.override {
    stdenv = s;
    enableLargeConfig = true;
    initialMarkStackSize = 1048576; # as nixpkgs sets for Nix
  };
  candidate = p.nixVersions.nix_2_28.override {
    stdenv = s;
    inherit boost curl sqlite boehmgc;
    busybox-sandbox-shell = busyboxSandboxShell;
    libblake3 = blake3;
    nlohmann_json = p.nlohmann_json.overrideAttrs { doCheck = false; };
    toml11 = p.toml11.overrideAttrs { doCheck = false; };
    withAWS = false;
    enableDocumentation = false;
  };
in
assert p.stdenv.hostPlatform.isMusl;
if !enableUnvalidated then throw "musl-nix is experimental; enable it through the musl constructor's withNix = true" else
(candidate.overrideAttrs (old: {
  doCheck = false;
  separateDebugInfo = false;
  dontStrip = false;
  mesonFlags = (map (flag: if flag == "-Dunit-tests=true" then "-Dunit-tests=false" else flag) old.mesonFlags)
    ++ [ "-Db_lto=false" ];
  # Meson rejects -Dbuildtype next to the --buildtype the setup hook passes.
  mesonBuildType = "release";
  # libutil calls syscall(SYS_close_range) and only gets the number through
  # libstdc++'s transitive includes; libc++ on musl does not pull it in.
  env = (old.env or { }) // {
    NIX_CFLAGS_COMPILE = toString [ (old.env.NIX_CFLAGS_COMPILE or "") "-include sys/syscall.h" ];
  };
  # nixpkgs hardcodes the compiler library path after copying Boost; libc++
  # lives separately when using libcxxStdenv. Do not retain the host compiler
  # library path, which can pull glibc into the target closure.
  preConfigure = builtins.replaceStrings
    [ "${p.lib.getLib s.cc.cc}/lib" "libboost_context*,libboost_thread*,libboost_system*" ]
    [ "${p.lib.getLib s.cc.libcxx}/lib:${p.lib.getLib p.pkgsLLVM.llvmPackages.libunwind}/lib" "libboost_context*,libboost_thread*,libboost_atomic*,libboost_chrono*,libboost_container*,libboost_date_time*" ]
    old.preConfigure;
})).overrideAttrs (old: {
  meta = old.meta // {
    description = "Experimental Nix built for musl with LLVM libc++";
  };
})
