# One s6 supervision tree per logged-in user; see user-manager.sh.
{
  lib,
  replaceVarsWith,
  bash,
  coreutils,
  util-linux,
  getent,
  gnugrep,
  s6,
  s6-rc,
  nixithos,
}:

replaceVarsWith {
  name = "user-manager";
  src = ./user-manager.sh;
  dir = "bin";
  isExecutable = true;

  replacements = {
    shell = "${bash}/bin/bash";
    path = lib.makeBinPath [
      coreutils
      util-linux
      getent
      gnugrep
      s6
      s6-rc
      # (unit-pam)
      nixithos.unitTools
    ];
    defaultPath = "/run/wrappers/bin:/run/current-system/sw/bin";
  };

  postInstall = ''
    ${bash}/bin/bash -n $target
  '';

  meta = {
    description = "Per-user s6 service managers, started by PAM";
    mainProgram = "user-manager";
    platforms = lib.platforms.linux;
  };
}
