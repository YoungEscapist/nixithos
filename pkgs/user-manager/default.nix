# One service manager per logged-in user (an s6 tree, or dinit --user); see
# user-manager.sh.
{
  lib,
  replaceVarsWith,
  bash,
  coreutils,
  util-linux,
  getent,
  gnugrep,
  diffutils,
  findutils,
  s6,
  s6-rc,
  dinit,
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
      # (cmp, for a switch of dinit --user)
      diffutils
      findutils
      s6
      s6-rc
      # (unit-pam)
      nixithos.unitTools
    ];
    defaultPath = "/run/wrappers/bin:/run/current-system/sw/bin";
    # (by their paths, not dinit's bin/ in PATH: its shutdown, halt and
    # reboot would come before the shim's for whatever runs from here)
    dinit = "${dinit}/bin/dinit";
    dinitctl = "${dinit}/bin/dinitctl";
  };

  postInstall = ''
    ${bash}/bin/bash -n $target
  '';

  meta = {
    description = "Per-user service managers (s6 or dinit), started by PAM";
    mainProgram = "user-manager";
    platforms = lib.platforms.linux;
  };
}
