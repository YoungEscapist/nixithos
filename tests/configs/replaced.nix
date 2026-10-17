# The minimal system on the packages of the binary cache, with libsystemd and
# libudev swapped for elogind's and eudev's.
{ ... }:

{
  imports = [ ./minimal.nix ];

  s6.systemdPackages = "replace";
}
