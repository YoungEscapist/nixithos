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
  openxr-loader,
  ffmpeg,
  mpv,
  curl,
  pulseaudio,
  python3,
  # a program the session runs alongside the compositor, given the
  # compositor's pid (NixithOS's: wallpapers, the clipboard's history,
  # notifications; ../../modules/desktop/desktops.nix)
  autostart ? null,
}:

rustPlatform.buildRustPackage (finalAttrs: {
  pname = "parallax";
  version = "0.1.0-unstable-2026-10-18";

  src = fetchFromGitHub {
    owner = "YoungEscapist";
    repo = "parallax-wm";
    rev = "558721067c0f6e44f7e7465772ba97aa29beeba5"; # ветка nixith-20261018: frame callback'и сразу после кадра
    hash = "sha256-PVLgQcCOMugc2AGQoqbmJlQjrnm4mFw5PXmk2WtHHoM=";
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
    install -Dm644 default_config.ru.lua $out/share/parallax/default_config.ru.lua
    install -Dm644 dist/shaders/haze.frag $out/share/parallax/shaders/haze.frag
    # the heart of the `love` gesture, and sharing the desktop from a terminal
    install -Dm755 dist/plx-heart $out/bin/plx-heart
    install -Dm755 plx-host $out/bin/plx-host
    substituteInPlace $out/bin/plx-host --replace-fail '#!/usr/bin/env python3' '#!${python3.interpreter}'
  ''
  + lib.optionalString (autostart != null) ''
    # (exec keeps the pid: the compositor's is ours; --prepare first, so
    # that a new user's configuration is there before the compositor reads it)
    # The session's log (the compositor's and the programs it starts), with
    # the previous session's beside it: a display manager keeps none.
    substituteInPlace $out/bin/parallax-session \
      --replace-fail 'exec "$PLX_BINARY" "$@"' 'logdir=''${XDG_STATE_HOME:-$HOME/.local/state}/parallax
    if mkdir -p "$logdir"; then
        [ -f "$logdir/session.log" ] && mv -f "$logdir/session.log" "$logdir/session.log.old"
        exec >"$logdir/session.log" 2>&1
    fi
    # (warnings and errors: the missing theme of the pointer, a failed device)
    export RUST_LOG=''${RUST_LOG:-warn}
    ${autostart} --prepare '"$out"'/share/parallax
    ${autostart} $$ &
    exec "$PLX_BINARY" "$@"'
  '';

  # what it opens at run time (EGL and the winit backend), and Xwayland
  postFixup = ''
    patchelf --add-rpath ${
      lib.makeLibraryPath [
        libGL
        libxkbcommon
        wayland
        # (VR loads libopenxr_loader.so when asked for, Entry::load)
        openxr-loader
      ]
    } $out/bin/plx-extra
    wrapProgram $out/bin/plx-extra --prefix PATH : ${
      lib.makeBinPath [
        xwayland
        dbus
        # what it runs itself: ffmpeg (video to guests), mpv and curl (live
        # and online pictures), pactl (the sound menu)
        ffmpeg
        mpv
        curl
        pulseaudio
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
