# The graphical installer: Calamares with NixOS's modules for it
# (calamares-nixos-extensions), made into NixithOS's.  What it installs is
# NixithOS because `nixith install` evaluates it through this tree
# (lib/nixith.nix); what changes here
# is what it shows and offers:
#
#   - the branding: the name, the mark, black and white;
#   - the desktops: NixithOS's (nixithos.desktop.*: dwl, Parallax, GNOME,
#     Plasma, Hyprland, niri) or none, in place of NixOS's with GDM and
#     SDDM; then what to log in through (ly, greetd, the console), the
#     user's shell and the boot loader: steps of their own;
#   - the configuration in /etc/nixith, through `nixith generate-config` and
#     `nixith install` (./patch-main.py).
{
  lib,
  calamares-nixos,
  calamares-nixos-extensions,
  imagemagick,
  python3,
  artwork,
}:

let
  extensions = calamares-nixos-extensions.overrideAttrs (old: {
    pname = "calamares-nixithos-extensions";
    nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [
      imagemagick
      python3
    ];
    postInstall = (old.postInstall or "") + ''
      b=$out/share/calamares/branding
      cp -r $b/nixos $b/nixithos
      chmod -R u+w $b/nixithos
      rm -f $b/nixithos/*.png $b/nixithos/*.svg $b/nixithos/show.qml
      # the mark's lines without its black square: white ones for the black
      # sidebar, black ones for the light welcome page (the brightness of the
      # picture becomes its opacity)
      logo=${artwork}/share/icons/hicolor/512x512/apps/nixithos.png
      magick $logo -colorspace Gray -alpha copy -fill white -colorize 100 $b/nixithos/nixithos.png
      magick $logo -colorspace Gray -alpha copy -fill black -colorize 100 $b/nixithos/nixithos-welcome.png
      # every choice shows itself: screenshots of NixithOS, taken in QEMU
      # (the desktops, the shells in a terminal, ly/greetd/the console, the
      # boot loaders' menus), on black at 16:10; the slides use them too
      rm -f $b/nixithos/images/*
      for shot in ${../../branding/screenshots}/*.png; do
        magick $shot -resize 1024x640 -background black -gravity center -extent 1024x640 \
          -quality 90 $b/nixithos/images/$(basename $shot .png).jpg
      done
      cp ${./branding.desc} $b/nixithos/branding.desc
      cp ${./show.qml} $b/nixithos/show.qml
      substituteInPlace $b/nixithos/notesqml@unfree.qml \
        --replace-fail 'qsTr("NixOS is fully open source' 'qsTr("NixithOS, like NixOS, is fully open source'

      c=$out/etc/calamares
      substituteInPlace $c/settings.conf --replace-fail "branding: nixos" "branding: nixithos"
      cp ${./packagechooser.conf} $c/modules/packagechooser.conf
      for step in displaymanager shell bootloader; do
        cp ${./.}/packagechooser-$step.conf $c/modules/
      done
      python3 ${./patch-settings.py} $c/settings.conf

      python3 ${./patch-main.py} $out/lib/calamares/modules/nixos/main.py
    '';
  });
in
(calamares-nixos.override { calamares-nixos-extensions = extensions; }).overrideAttrs (old: {
  passthru = (old.passthru or { }) // {
    inherit extensions;
  };
})
