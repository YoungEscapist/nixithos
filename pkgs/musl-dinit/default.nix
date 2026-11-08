# Build-time GNU tools are fine; the shipped executables use musl and libc++.
{ lib, stdenvNoCC, zig, gnumake, m4, dinit }:
stdenvNoCC.mkDerivation {
  pname = "dinit-musl";
  inherit (dinit) version src;
  nativeBuildInputs = [ zig gnumake m4 ];
  strictDeps = true;
  dontUseZigConfigure = true;
  dontUseZigBuild = true;
  dontUseZigInstall = true;
  configurePhase = ''
    runHook preConfigure
    export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-global"
    export ZIG_LOCAL_CACHE_DIR="$TMPDIR/zig-local"
    export CXX="${zig}/bin/zig c++ -target ${if stdenvNoCC.hostPlatform.isx86_64 then "x86_64" else "aarch64"}-linux-musl"
    export CXXFLAGS='-std=c++11 -O2 -fno-omit-frame-pointer'
    export LDFLAGS='-static -s'
    ./configure --prefix="$out" --sbindir="$out/bin" --disable-capabilities --disable-utmpx --disable-strip
    runHook postConfigure
  '';
  enableParallelBuilding = true;
  dontPatchELF = true;
  # No libc, compiler, shell or auxiliary utility store references may escape.
  allowedReferences = [ "out" ];
  meta = {
    description = "Dinit with static musl and LLVM libc++ for the strict profile";
    license = lib.licenses.asl20;
    platforms = [ "x86_64-linux" "aarch64-linux" ];
  };
}
