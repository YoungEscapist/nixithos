# The unit compiler.  Build-time only: it is never part of a system closure.
{
  lib,
  stdenvNoCC,
  python3,
}:

stdenvNoCC.mkDerivation {
  pname = "unitc";
  version = "0.1.0";

  src = ./unitc.py;
  dontUnpack = true;

  buildInputs = [ python3 ];

  installPhase = ''
    install -Dm755 $src $out/bin/unitc
    patchShebangs $out/bin/unitc
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    ${python3.interpreter} -m py_compile $src
    $out/bin/unitc --help > /dev/null
  '';

  meta = {
    description = "Compiles systemd unit files into s6-rc service definitions";
    mainProgram = "unitc";
    platforms = lib.platforms.linux;
  };
}
