# Small C helpers used by unit-runtime for the things a shell cannot do:
# binding sockets, speaking sd_notify, keeping timers, PAM sessions; and a PAM
# module for the session's environment (pam_s6_env).
{
  lib,
  stdenv,
  pam,
}:

stdenv.mkDerivation {
  pname = "unit-tools";
  version = "0.1.0";

  src = lib.cleanSourceWith {
    src = ./.;
    filter = path: _type: lib.hasSuffix ".c" path;
  };

  # (unit-pam)
  buildInputs = [ pam ];

  dontConfigure = true;

  buildPhase = ''
    runHook preBuild
    for src in unit-*.c; do
      libs=
      [ "$src" = unit-pam.c ] && libs=-lpam
      $CC -std=gnu11 -O2 -Wall -Wextra -Wno-unused-parameter -o "''${src%.c}" "$src" $libs
    done
    # PAM modules
    for src in pam_*.c; do
      $CC -std=gnu11 -O2 -Wall -Wextra -Wno-unused-parameter -shared -fPIC -o "''${src%.c}.so" "$src" -lpam
    done
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    for src in unit-*.c; do
      install -Dm755 "''${src%.c}" "$out/bin/''${src%.c}"
    done
    for src in pam_*.c; do
      install -Dm644 "''${src%.c}.so" "$out/lib/security/''${src%.c}.so"
    done
    runHook postInstall
  '';

  meta = {
    description = "Helpers for running systemd-style units under s6";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
  };
}
