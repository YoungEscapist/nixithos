{ lib, stdenvNoCC, busybox }:
stdenvNoCC.mkDerivation {
  pname = "musl-unit-runtime";
  version = "1";
  dontUnpack = true;
  installPhase = ''
    mkdir -p "$out/bin"
    substitute ${./unit-runtime.sh} "$out/bin/unit-runtime" \
      --replace-fail '@ash@' '${busybox}/bin/ash'
    chmod +x "$out/bin/unit-runtime"
    ${busybox}/bin/ash -n "$out/bin/unit-runtime"
  '';
  meta = {
    description = "Strict BusyBox service wrapper dispatcher";
    mainProgram = "unit-runtime";
    platforms = lib.platforms.linux;
  };
}
