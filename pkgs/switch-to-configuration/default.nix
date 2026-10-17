# switch-to-configuration for s6-rc; see the script.
{
  lib,
  replaceVarsWith,
  bash,
  coreutils,
  gnugrep,
  gnused,
  util-linux,
  s6,
  s6-rc,
  nixithos,
}:

replaceVarsWith {
  name = "switch-to-configuration";
  src = ./switch-to-configuration.sh;
  dir = "bin";
  isExecutable = true;

  replacements = {
    shell = "${bash}/bin/bash";
    path = lib.makeBinPath [
      coreutils
      gnugrep
      gnused
      util-linux
      s6
      s6-rc
    ];
    runtime = "${nixithos.unitRuntime}/bin/unit-runtime";
    userManager = "${nixithos.userManager}/bin/user-manager";
  };

  postInstall = ''
    ${bash}/bin/bash -n $target
  '';

  meta = {
    description = "Activates a system configuration on an s6-rc based NixOS";
    mainProgram = "switch-to-configuration";
    platforms = lib.platforms.linux;
  };
}
