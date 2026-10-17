# org.freedesktop.systemd1 on a user's session bus (./systemd1-bus.py): the
# D-Bus face of the s6 user manager, for gnome-session.
{
  lib,
  runCommand,
  python3,
  glib,
  gobject-introspection,
  makeWrapper,
}:

let
  python = python3.withPackages (p: [ p.pygobject3 ]);
in
runCommand "systemd1-bus"
  {
    nativeBuildInputs = [ makeWrapper ];
    meta.mainProgram = "systemd1-bus";
  }
  ''
    install -Dm755 ${./systemd1-bus.py} $out/libexec/systemd1-bus.py
    patchShebangs $out/libexec
    makeWrapper ${python}/bin/python3 $out/bin/systemd1-bus \
      --add-flags $out/libexec/systemd1-bus.py \
      --prefix GI_TYPELIB_PATH : ${lib.getLib glib}/lib/girepository-1.0:${lib.getLib gobject-introspection}/lib/girepository-1.0
  ''
