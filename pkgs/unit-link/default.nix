# systemd.link(5) files applied for eudev; see unit-link.sh.
{
  lib,
  replaceVarsWith,
  bash,
  coreutils,
  gnugrep,
  gnused,
  iproute2,
  ethtool,
  util-linux,
}:

replaceVarsWith {
  name = "unit-link";
  src = ./unit-link.sh;
  dir = "bin";
  isExecutable = true;
  replacements = {
    shell = "${bash}/bin/bash";
    path = lib.makeBinPath [
      coreutils
      gnugrep
      gnused
      iproute2
      ethtool
      util-linux
    ];
  };
  postInstall = ''
    ${bash}/bin/bash -n $target
  '';
  meta.mainProgram = "unit-link";
}
