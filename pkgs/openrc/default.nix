# OpenRC (nixpkgs has none), the way a NixOS wants it: the programs and
# libraries in the store, but the configuration where OpenRC looks for it
# unchanged - /etc/rc.conf, /etc/init.d, /etc/runlevels, /etc/conf.d - and its
# state in /run/openrc.  The files meson would put under /etc (the stock init
# scripts, rc.conf) are kept in share/openrc/etc, for reference: the system
# builds its own.
{
  lib,
  stdenv,
  fetchFromGitHub,
  meson,
  ninja,
  pkg-config,
  libcap,
  bash,
  # where OpenRC looks for init.d/ (and conf.d/): /etc for what the system
  # adds, and the database of the services in use (unitc --init openrc), which
  # a switch changes by moving a link
  rcPath ? [
    "/etc"
    "/run/units/.db/openrc"
  ],
}:

stdenv.mkDerivation rec {
  pname = "openrc";
  version = "0.64.1";

  src = fetchFromGitHub {
    owner = "OpenRC";
    repo = "openrc";
    rev = version;
    hash = "sha256:08wxmr544gdp2aqwpn6jqybnvkm7iq837x39b2nj5mqr6vvgapj2";
  };

  nativeBuildInputs = [
    meson
    ninja
    pkg-config
  ];
  buildInputs = [ libcap ];

  # (the scripts in the package have /bin/sh in them: the one of bash)
  mesonFlags = [
    "--prefix=${placeholder "out"}"
    "--sysconfdir=/etc"
    "--bindir=bin"
    "--sbindir=sbin"
    "--libexecdir=libexec"
    "-Dshell=${bash}/bin/sh"
    "-Daudit=disabled"
    "-Dselinux=disabled"
    "-Drc_path=${lib.concatStringsSep "," rcPath}"
    "-Dpam=false"
    "-Dsysvinit=false"
    "-Dnewnet=false"
    "-Dpkgconfig=false"
  ];

  # openrc-init sets PATH to the directories of a FHS system, where `openrc`
  # is not: it keeps the one its init script gave it.
  postPatch = ''
    substituteInPlace src/openrc-init/openrc-init.c \
      --replace-fail 'setenv("PATH", path_default, 1)' 'setenv("PATH", path_default, 0)'
  '';

  # The configuration goes to /etc, which a build cannot write to: it is
  # installed under a root of its own, and moved from there.
  installPhase = ''
    runHook preInstall
    DESTDIR=$PWD/dest meson install --no-rebuild
    mkdir -p $out
    mv dest$out/* $out/
    mkdir -p $out/share/openrc
    mv dest/etc $out/share/openrc/etc
    runHook postInstall
  '';

  meta = {
    description = "Dependency-based init system";
    homepage = "https://github.com/OpenRC/openrc";
    license = lib.licenses.bsd2;
    platforms = lib.platforms.linux;
    mainProgram = "openrc";
  };
}
