{ lib, stdenvNoCC, busybox, dinit }:
stdenvNoCC.mkDerivation {
  pname = "nixith-musl-control";
  version = "0.1.0";
  dontUnpack = true;
  installPhase = ''
    mkdir -p "$out/bin"
    substitute ${./nixith.sh} "$out/bin/nixith" \
      --replace-fail '@shell@' '${busybox}/bin/ash' \
      --replace-fail '@busybox@' '${busybox}/bin/busybox' \
      --replace-fail '@dinitctl@' '${dinit}/bin/dinitctl' \
      --replace-fail '@dinitcheck@' '${dinit}/bin/dinit-check' \
      --replace-fail '@shutdown@' '${dinit}/bin/shutdown'
    chmod +x "$out/bin/nixith"
    ${busybox}/bin/ash -n "$out/bin/nixith"
  '';
  meta = {
    description = "BusyBox ash system control for the strict musl profile";
    mainProgram = "nixith";
    platforms = lib.platforms.linux;
  };
}
