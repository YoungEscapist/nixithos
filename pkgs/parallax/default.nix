# Parallax (github.com/YoungEscapist/parallax-wm): a Wayland compositor where
# windows live on one infinite canvas and the screen is a camera over it.
# The plx-extra build (everything: the GPU decorations, the cube of desks,
# guest sharing; the VR headset only loads OpenXR when asked for), with the
# session script of the repository (dist/parallax-session) and its entry for
# display managers.
{
  lib,
  rustPlatform,
  fetchFromGitHub,
  pkg-config,
  makeWrapper,
  libxkbcommon,
  wayland,
  libGL,
  mesa,
  libgbm,
  libdrm,
  libinput,
  udev,
  seatd,
  pipewire,
  pixman,
  libdisplay-info,
  xwayland,
  dbus,
}:

rustPlatform.buildRustPackage (finalAttrs: {
  pname = "parallax";
  version = "0.1.0-unstable-2026-10-12";

  src = fetchFromGitHub {
    owner = "YoungEscapist";
    repo = "parallax-wm";
    rev = "263701090e8b6dd85527d487a07d538c04503cd7";
    hash = "sha256-KBK65f5sLyezClTohYlzYcuoHVJAcfIkxcHHz2EsIis=";
  };

  cargoHash = "sha256-QbbQI84MnObdbDjqkzY3cfJkIelhP1Ihvc3AE5q4mmY=";

  # (one binary: building both members at once would give plx-standard the
  # features of plx-extra, cargo unifies them across a workspace)
  cargoBuildFlags = [
    "-p"
    "plx-extra"
  ];
  doCheck = false;

  nativeBuildInputs = [
    pkg-config
    makeWrapper
    rustPlatform.bindgenHook
  ];

  buildInputs = [
    libxkbcommon
    wayland
    libGL
    mesa
    libgbm
    libdrm
    libinput
    udev
    seatd
    pipewire
    pixman
    libdisplay-info
  ];

  # (build.rs asks git for the commit; there is no .git here)
  env.PLX_COMMIT = builtins.substring 0 7 finalAttrs.src.rev;

  postInstall = ''
    install -Dm755 dist/parallax-session $out/bin/parallax-session
    substituteInPlace $out/bin/parallax-session \
      --replace-fail '@CHECKOUT@' /nonexistent \
      --replace-fail 'if [ -z "$PLX_BINARY" ]; then' 'PLX_BINARY=''${PLX_BINARY:-'"$out"'/bin/plx-extra}
    if [ -z "$PLX_BINARY" ]; then'
    install -Dm644 dist/parallax.desktop $out/share/wayland-sessions/parallax.desktop
    substituteInPlace $out/share/wayland-sessions/parallax.desktop \
      --replace-fail /usr/local/bin/parallax-session $out/bin/parallax-session
    install -Dm644 default_config.lua $out/share/parallax/default_config.lua
  '';

  # what it opens at run time (EGL and the winit backend), and Xwayland
  postFixup = ''
    patchelf --add-rpath ${
      lib.makeLibraryPath [
        libGL
        libxkbcommon
        wayland
      ]
    } $out/bin/plx-extra
    wrapProgram $out/bin/plx-extra --prefix PATH : ${
      lib.makeBinPath [
        xwayland
        dbus
      ]
    }
  '';

  passthru.providedSessions = [ "parallax" ];

  meta = {
    description = "Wayland compositor with an infinite canvas, the screen a camera over it";
    homepage = "https://github.com/YoungEscapist/parallax-wm";
    license = lib.licenses.gpl3Plus;
    mainProgram = "plx-extra";
    platforms = lib.platforms.linux;
  };
})
