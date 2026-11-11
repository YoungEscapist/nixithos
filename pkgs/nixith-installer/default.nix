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
  cryptsetup,
  gnused,
  gnugrep,
  # the kernels the installer offers: only their versions, for the names
  linuxPackages,
  linuxPackages_latest,
  linuxPackages_6_12,
  linuxPackages_6_6,
  linuxPackages_zen,
  linuxPackages_xanmod_latest,
  # the release of this nixpkgs, and the other one the installer offers
  # (../../lib/nixpkgs-unstable.json): its release and its kernels, by name
  # only - nothing of it is built or put on the image
  unstablePkgs ? import (import ../../lib/pin.nix ../../lib/nixpkgs-unstable.json) {
    inherit (stdenv.hostPlatform) system;
    config = { };
    overlays = [ ];
  },
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
      -DK_LTS=\"${linuxPackages.kernel.version}\" \
      -DK_LATEST=\"${linuxPackages_latest.kernel.version}\" \
      -DK_6_12=\"${linuxPackages_6_12.kernel.version}\" \
      -DK_6_6=\"${linuxPackages_6_6.kernel.version}\" \
      -DK_ZEN=\"${linuxPackages_zen.kernel.version}\" \
      -DK_XANMOD=\"${linuxPackages_xanmod_latest.kernel.version}\" \
      -DKU_LTS=\"${unstablePkgs.linuxPackages.kernel.version}\" \
      -DKU_LATEST=\"${unstablePkgs.linuxPackages_latest.kernel.version}\" \
      -DKU_6_12=\"${unstablePkgs.linuxPackages_6_12.kernel.version}\" \
      -DKU_6_6=\"${unstablePkgs.linuxPackages_6_6.kernel.version}\" \
      -DKU_ZEN=\"${unstablePkgs.linuxPackages_zen.kernel.version}\" \
      -DKU_XANMOD=\"${unstablePkgs.linuxPackages_xanmod_latest.kernel.version}\" \
      -DR_STABLE=\"${lib.trivial.release}\" \
      -DR_STABLE_NAME=\"${lib.trivial.codeName}\" \
      -DR_UNSTABLE=\"${unstablePkgs.lib.trivial.release}\" \
      -DR_UNSTABLE_NAME=\"${unstablePkgs.lib.trivial.codeName}\" \
      -DPINS=\"$out/share/nixith-installer/pins\" \
      -I${stb}/include/stb \
      -o nixith-installer installer.c $(pkg-config --cflags --libs ncursesw) -lcrypt -lm
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 nixith-installer $out/bin/nixith-installer
    install -Dm755 install.sh $out/libexec/nixith-installer/install.sh
    # screenshots of each desktop, login screen, shell and
    # boot loader, taken in QEMU): on black at 16:10, as it had them
    mkdir -p $out/share/nixith-installer/screenshots
    for shot in ${../../branding/screenshots}/*.png; do
      magick $shot -resize 1024x640 -background black -gravity center -extent 1024x640 \
        -quality 90 $out/share/nixith-installer/screenshots/$(basename $shot .png).jpg
    done
    # the nixpkgs revisions of the releases (NI_PINS of install.sh)
    install -Dm644 ${../../lib/nixpkgs.json} $out/share/nixith-installer/pins/nixpkgs.json
    install -Dm644 ${../../lib/nixpkgs-unstable.json} $out/share/nixith-installer/pins/nixpkgs-unstable.json
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
          cryptsetup
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
