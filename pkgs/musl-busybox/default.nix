# The target executable is built by LLVM/Zig with musl and compiler-rt.
# Merely making GCC's BusyBox static would hide its compiler runtime provenance.
{ lib, stdenvNoCC, stdenv, zig, gnumake, perl, busybox }:
let
  target = "${if stdenvNoCC.hostPlatform.isx86_64 then "x86_64" else "aarch64"}-linux-musl";
in
stdenvNoCC.mkDerivation {
  pname = "busybox-musl";
  inherit (busybox) version src patches;
  nativeBuildInputs = [ zig gnumake perl stdenv.cc ];
  strictDeps = true;
  dontUseZigConfigure = true;
  dontUseZigBuild = true;
  dontUseZigInstall = true;
  postPatch = ''
    # Zig's ELF linker accepts the link itself but does not implement GNU ld's
    # optional diagnostic/map switches. Keep BusyBox's capability probes and
    # library resolution, omitting only this informational final-link suffix.
    substituteInPlace scripts/trylink \
      --replace-fail 'echo "-Wl,--warn-common -Wl,-Map,$EXE.map -Wl,--verbose"' ':'
  '';
  configurePhase = ''
    runHook preConfigure
    export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-global"
    export ZIG_LOCAL_CACHE_DIR="$TMPDIR/zig-local"
    export KCONFIG_NOTIMESTAMP=1
    make defconfig HOSTCC=${stdenv.cc}/bin/cc
    configure_option() {
      sed -i "/^$1=/d; /^# $1 is not set$/d" .config
      printf '%s=%s\n' "$1" "$2" >> .config
    }
    configure_option CONFIG_STATIC y
    configure_option CONFIG_STATIC_LIBGCC n
    configure_option CONFIG_PIE n
    configure_option CONFIG_PREFIX '"'$out'"'
    configure_option CONFIG_INSTALL_NO_USR y
    configure_option CONFIG_LFS y
    configure_option CONFIG_FEATURE_UTMP n
    configure_option CONFIG_FEATURE_WTMP n
    configure_option CONFIG_FEATURE_MOUNT_CIFS n
    configure_option CONFIG_FEATURE_MOUNT_HELPERS n
    configure_option CONFIG_FEATURE_MODPROBE_BLACKLIST y
    configure_option CONFIG_FEATURE_MODUTILS_ALIAS y
    configure_option CONFIG_FEATURE_MODUTILS_SYMBOLS y
    configure_option CONFIG_MODPROBE_SMALL n
    configure_option CONFIG_USE_BB_CRYPT y
    configure_option CONFIG_USE_BB_CRYPT_SHA y
    configure_option CONFIG_TC n
    configure_option CONFIG_UDHCPC_DEFAULT_SCRIPT '"/etc/udhcpc.script"'
    make oldconfig HOSTCC=${stdenv.cc}/bin/cc
    runHook postConfigure
  '';
  buildPhase = ''
    runHook preBuild
    make -j"$NIX_BUILD_CORES" \
      HOSTCC=${stdenv.cc}/bin/cc \
      CC='${zig}/bin/zig cc -target ${target}' \
      AR='${zig}/bin/zig ar' \
      SKIP_STRIP=y
    runHook postBuild
  '';
  installPhase = ''
    runHook preInstall
    make install CONFIG_PREFIX="$out" \
      HOSTCC=${stdenv.cc}/bin/cc \
      CC='${zig}/bin/zig cc -target ${target}' \
      AR='${zig}/bin/zig ar' \
      SKIP_STRIP=y
    # Supply the conventional flat Nix package layout used by the profile.
    for directory in "$out/sbin" "$out/usr/bin" "$out/usr/sbin"; do
      if [ -d "$directory" ]; then
        for applet in "$directory"/*; do
          [ -L "$applet" ] || continue
          ln -sf busybox "$out/bin/$(basename "$applet")"
        done
        rm -r "$directory"
      fi
    done
    runHook postInstall
  '';
  dontPatchELF = true;
  allowedReferences = [ "out" ];
  passthru.shellPath = "/bin/ash";
  meta = {
    description = "Static BusyBox with musl and LLVM compiler-rt";
    license = lib.licenses.gpl2Only;
    mainProgram = "busybox";
    platforms = [ "x86_64-linux" "aarch64-linux" ];
  };
}
