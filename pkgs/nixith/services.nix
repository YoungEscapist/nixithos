# nixith services: the console list of the system's units (./services.c).
{
  lib,
  stdenv,
  pkg-config,
  ncurses,
}:

stdenv.mkDerivation {
  pname = "nixith-services";
  version = "0.1";

  src = lib.fileset.toSource {
    root = ./.;
    fileset = ./services.c;
  };

  nativeBuildInputs = [ pkg-config ];
  buildInputs = [ ncurses ];

  buildPhase = ''
    runHook preBuild
    $CC -O2 -Wall -o nixith-services services.c $(pkg-config --cflags --libs ncursesw)
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 nixith-services $out/bin/nixith-services
    runHook postInstall
  '';

  meta = {
    description = "A console list of the units of a NixithOS system, with status and start/stop";
    license = lib.licenses.mit;
    mainProgram = "nixith-services";
    platforms = lib.platforms.linux;
  };
}
