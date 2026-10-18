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
    rev = "23730924d8598b04bb0d99fd60c41b222b4b8d10";
    hash = "sha256-WAEFegRQ7beKzxFKHo+eJirJ/qn0SvT1Ek30aRO+0p0=";
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
  ];

  doCheck = false;

  # what it runs: ffmpeg/ffprobe for thumbnails and previews, curl for the
  # online sources, nice, pkill; zenity to pick a file of one's own (rofi or
  # fuzzel, for a list, are found in the session's PATH)
  postFixup = ''
    wrapProgram $out/bin/plx-wall \
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
