# The minimal system on the packages of the binary cache, i.e. with the
# systemd libraries still linked into some of them.
{ ... }:

{
  imports = [ ./minimal.nix ];

  s6.systemdPackages = "keep";
}
