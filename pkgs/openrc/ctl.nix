# openrcctl: dinitctl's commands, put to OpenRC; see openrcctl.sh.
{
  lib,
  replaceVarsWith,
  bash,
  coreutils,
  gnused,
  util-linux,
  nixithos,
}:

replaceVarsWith {
  name = "openrcctl";
  src = ./openrcctl.sh;
  dir = "bin";
  isExecutable = true;

  replacements = {
    shell = "${bash}/bin/bash";
    path = lib.makeBinPath [
      coreutils
      gnused
      util-linux
    ];
    openrc = nixithos.openrc;
  };

  postInstall = ''
    ${bash}/bin/bash -n $target
  '';

  meta = {
    description = "dinitctl's commands over OpenRC";
    mainProgram = "openrcctl";
    platforms = lib.platforms.linux;
  };
}
