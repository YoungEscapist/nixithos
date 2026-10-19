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
  imagemagick,
  ncurses,
  libxcrypt,
  stb,
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
    imagemagick
  ];
  buildInputs = [
    ncurses
    libxcrypt
    stb
  ];

  buildPhase = ''
    runHook preBuild
    $CC -O2 -Wall -Wno-missing-field-initializers -Wno-format-truncation -Wno-stringop-truncation \
      -DINSTALL_SH=\"$out/libexec/nixith-installer/install.sh\" \
      -DSHOTS=\"$out/share/nixith-installer/screenshots\" \
      -I${stb}/include/stb \
      -o nixith-installer installer.c $(pkg-config --cflags --libs ncursesw) -lcrypt -lm
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 nixith-installer $out/bin/nixith-installer
    install -Dm755 install.sh $out/libexec/nixith-installer/install.sh
    # the screenshots Calamares showed (each desktop, login screen, shell and
    # boot loader, taken in QEMU): on black at 16:10, as it had them
    mkdir -p $out/share/nixith-installer/screenshots
    for shot in ${../../branding/screenshots}/*.png; do
      magick $shot -resize 1024x640 -background black -gravity center -extent 1024x640 \
        -quality 90 $out/share/nixith-installer/screenshots/$(basename $shot .png).jpg
    done
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
