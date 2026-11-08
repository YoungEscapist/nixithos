# A disposable QEMU system. The empty root password is explicit and intended
# for the local serial console only; omit rootPasswordHash to lock root login.
{ pkgs, ... }:
{
  hostname = "nixith-musl";
  console = "ttyS0";
  rootPasswordHash = "";
  networking.enableDHCP = true;
  packages = [ ];
  services.hello = {
    type = "scripted";
    command = [ "${pkgs.busybox}/bin/echo" "Hello from musl and BusyBox" ];
  };
}
