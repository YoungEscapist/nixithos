# The file system view of a sandboxed unit; see unit-sandbox.sh.
{
  lib,
  replaceVarsWith,
  bash,
  coreutils,
  util-linux,
  gawk,
  gnugrep,
  iproute2,
  nixithos,
}:

replaceVarsWith {
  name = "unit-sandbox";
  src = ./unit-sandbox.sh;
  dir = "bin";
  isExecutable = true;

  replacements = {
    shell = "${bash}/bin/bash";
    path = lib.makeBinPath [
      coreutils
      util-linux
      gawk
      gnugrep
      iproute2
      nixithos.unitTools
    ];
  };

  postInstall = ''
    ${bash}/bin/bash -n $target
  '';

  meta = {
    description = "Mount namespace setup for systemd-style sandboxed units";
    mainProgram = "unit-sandbox";
    platforms = lib.platforms.linux;
  };
}
