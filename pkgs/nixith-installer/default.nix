# NixithOS's installer in the console (./installer.c, ./install.sh), and
# nixith-net: its network step on its own, a simpler nmtui.
#
#   sudo nixith-installer [--dry]
#   nixith-net
{
  lib,
  stdenv,
  makeWrapper,
  pkg-config,
  ncurses,
  libxcrypt,
  bash,
  coreutils,
  util-linux,
  parted,
  dosfstools,
  e2fsprogs,
  btrfs-progs,
  gnused,
  gnugrep,
}:

stdenv.mkDerivation {
  pname = "nixith-installer";
  version = "0.1";

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./installer.c
      ./install.sh
    ];
  };

  nativeBuildInputs = [
    makeWrapper
    pkg-config
  ];
  buildInputs = [
    ncurses
    libxcrypt
  ];

  buildPhase = ''
    runHook preBuild
    $CC -O2 -Wall -Wno-missing-field-initializers -Wno-format-truncation -Wno-stringop-truncation \
      -DINSTALL_SH=\"$out/libexec/nixith-installer/install.sh\" \
      -o nixith-installer installer.c $(pkg-config --cflags --libs ncursesw) -lcrypt
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 nixith-installer $out/bin/nixith-installer
    install -Dm755 install.sh $out/libexec/nixith-installer/install.sh
    patchShebangs $out/libexec
    # the tools of the installation first, then the system's (nmcli, nixith,
    # udevadm, reboot)
    wrapProgram $out/bin/nixith-installer \
      --prefix PATH : ${
        lib.makeBinPath [
          bash
          coreutils
          util-linux
          parted
          dosfstools
          e2fsprogs
          btrfs-progs
          gnused
          gnugrep
        ]
      } \
      --suffix PATH : /run/wrappers/bin:/run/current-system/sw/bin
    makeWrapper $out/bin/nixith-installer $out/bin/nixith-net --add-flags --net
    runHook postInstall
  '';

  meta = {
    description = "The installer of NixithOS, in the console";
    license = lib.licenses.mit;
    mainProgram = "nixith-installer";
    platforms = lib.platforms.linux;
  };
}
