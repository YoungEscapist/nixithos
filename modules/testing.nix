# Adjustments for nodes of automated VM tests (see ../lib/testing.nix).
{ lib, ... }:

{
  # The test driver talks to a shell on the serial console; a getty there
  # gets in its way (upstream disables serial-getty@ for the same reason).
  services.getty.kernelConsole = lib.mkDefault false;

  # Keep this tree out of the nodes' closure: otherwise editing any file in
  # it, documentation included, would make every test run again.
  s6.channel.enable = lib.mkDefault false;

  # No manual build for test nodes.
  documentation.enable = lib.mkDefault false;
}
