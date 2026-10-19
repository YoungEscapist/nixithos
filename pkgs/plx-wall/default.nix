# plx-wall (github.com/YoungEscapist/plx-wall): Parallax's wallpapers, still
# and live (mp4/gif, decoded by the GPU through ffmpeg's libraries into
# dmabufs), their picker (Super+W) and the palette taken from them for the
# terminals and the launcher.
{
  lib,
  rustPlatform,
  fetchFromGitHub,
  pkg-config,
  makeWrapper,
  wayland,
  libxkbcommon,
  ffmpeg,
  libva,
  libgbm,
  curl,
  coreutils,
  procps,
  zenity,
}:

rustPlatform.buildRustPackage {
  pname = "plx-wall";
  version = "0.1.0-unstable-2026-10-18";

  src = fetchFromGitHub {
    owner = "YoungEscapist";
    repo = "plx-wall";
    rev = "a15536a789a9fffd94b93d8183f05a7f1d680177"; # рабочее дерево /root/plx-wall-nixith 19.10 (GBM-dmabuf), не запушено
    hash = "sha256-yYk55mQi2old1lHhZBauW1MSmwLuwISHNc3LLoKry0M=";
  };

  cargoHash = "sha256-GHLewEOilCdC32bJ+nFAldkx31TxUmBITsvUVEMtQoQ=";

  nativeBuildInputs = [
    pkg-config
    makeWrapper
    # (build.rs has bindgen read ffmpeg's headers: the layout of AVFrame and
    # AVCodecContext changes from one version to the next)
    rustPlatform.bindgenHook
  ];

  buildInputs = [
    wayland
    libxkbcommon
    ffmpeg
    libva
    # (frames of live wallpapers go to the compositor in linear GBM buffers:
    # a dmabuf it samples as is, instead of a wl_shm it has to upload)
    libgbm
  ];

  doCheck = false;

  # what it runs: ffmpeg/ffprobe for thumbnails and previews, curl for the
  # online sources, nice, pkill; zenity to pick a file of one's own (rofi or
  # fuzzel, for a list, are found in the session's PATH)
  #
  # The program itself goes to libexec under its own name: wrapProgram would
  # rename it to .plx-wall-wrapped, the process would be called that, and
  # Parallax's binds (Super+W: `pkill -USR2 -x plx-wall`) would find nothing.
  postFixup = ''
    mkdir -p $out/libexec/plx-wall
    mv $out/bin/plx-wall $out/libexec/plx-wall/plx-wall
    makeWrapper $out/libexec/plx-wall/plx-wall $out/bin/plx-wall \
      --suffix PATH : ${
        lib.makeBinPath [
          ffmpeg
          curl
          coreutils
          procps
          zenity
        ]
      }
  '';

  meta = {
    description = "Wallpapers for Parallax: still and live, with a picker and a palette";
    homepage = "https://github.com/YoungEscapist/plx-wall";
    license = lib.licenses.gpl3Plus;
    mainProgram = "plx-wall";
    platforms = lib.platforms.linux;
  };
}
