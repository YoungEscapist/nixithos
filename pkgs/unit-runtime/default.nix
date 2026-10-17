# The program every compiled unit runs through; see unit-runtime.sh.
{
  lib,
  replaceVarsWith,
  runtimeShell,
  bash,
  coreutils,
  util-linux,
  gnugrep,
  gnused,
  gawk,
  getent,
  s6,
  execline,
  eudev,
  dbus,
  nixithos,

  # Where per-service logs go, and the s6-log directives used for them
  # (the log directory is appended).
  logDir ? "/var/log/s6",
  logScript ? "n10 s1000000 T",
  notificationFd ? 20,
  defaultPath ? "/run/wrappers/bin:/run/current-system/sw/bin:/run/current-system/sw/sbin",
  # Needed only for Type=dbus readiness; services still start without it.
  withDbus ? true,
}:

replaceVarsWith {
  name = "unit-runtime";
  src = ./unit-runtime.sh;
  dir = "bin";
  isExecutable = true;

  replacements = {
    bash = "${bash}/bin/bash";
    env = "${coreutils}/bin/env";
    bashLoadables = "${bash}/lib/bash";
    path = lib.makeBinPath (
      [
        coreutils
        util-linux
        gnugrep
        gnused
        gawk
        getent
        s6
        execline
        nixithos.unitTools
        eudev
      ]
      ++ lib.optional withDbus dbus
    );
    sandbox = "${nixithos.unitSandbox}/bin/unit-sandbox";
    inherit
      logDir
      logScript
      notificationFd
      defaultPath
      ;
  };

  postInstall = ''
    ${bash}/bin/bash -n $target
  '';

  passthru = {
    inherit logDir notificationFd;
  };

  meta = {
    description = "Runs systemd-style units as s6 services";
    mainProgram = "unit-runtime";
    platforms = lib.platforms.linux;
  };
}
