# EXPERIMENTAL: not wired into the system until built, closure-audited and tested.
# Pass a cross-musl package set; its C++ dependencies must use the same libc++ ABI.
{ crossPkgs, busyboxSandboxShell, enableUnvalidated ? false }:
let
  p = crossPkgs;
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
    ) old.configureFlags;
  });
  candidate = p.nixVersions.nix_2_28.override {
    stdenv = s;
    inherit boost curl sqlite;
    busybox-sandbox-shell = busyboxSandboxShell;
    libblake3 = blake3;
    nlohmann_json = p.nlohmann_json.overrideAttrs { doCheck = false; };
    toml11 = p.toml11.overrideAttrs { doCheck = false; };
    withAWS = false;
    enableDocumentation = false;
  };
in
assert p.stdenv.hostPlatform.isMusl;
if !enableUnvalidated then throw "musl-nix is experimental and has not passed runtime closure or functional audits" else
(candidate.overrideAttrs (old: {
  doCheck = false;
  separateDebugInfo = false;
  dontStrip = false;
  mesonFlags = (map (flag: if flag == "-Dunit-tests=true" then "-Dunit-tests=false" else flag) old.mesonFlags)
    ++ [ "-Dbuildtype=release" "-Db_lto=false" ];
  # nixpkgs hardcodes the compiler library path after copying Boost; libc++
  # lives separately when using libcxxStdenv. Do not retain the host compiler
  # library path, which can pull glibc into the target closure.
  preConfigure = builtins.replaceStrings
    [ "${p.lib.getLib s.cc.cc}/lib" "libboost_context*,libboost_thread*,libboost_system*" ]
    [ "${p.lib.getLib s.cc.libcxx}/lib:${p.lib.getLib p.pkgsLLVM.llvmPackages.libunwind}/lib" "libboost_context*,libboost_thread*,libboost_atomic*,libboost_chrono*,libboost_container*,libboost_date_time*" ]
    old.preConfigure;
})).overrideAttrs (old: {
  meta = old.meta // {
    description = "Experimental musl/libc++ Nix candidate (requires closure and runtime audit)";
  };
})
