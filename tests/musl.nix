# Integration test uses the actual target binaries; Python/QEMU stay on host.
{ nixpkgs ? import ../lib/nixpkgs.nix, system ? builtins.currentSystem }:
let
  p = import nixpkgs { inherit system; };
  make = configuration: import ../musl { inherit nixpkgs system configuration; };
  next = make ({ pkgs, ... }: {
    hostname = "nixith-musl-test";
    rootPasswordHash = "";
    networking.enableDHCP = true;
    services.token = {
      type = "scripted";
      command = [ "${pkgs.busybox}/bin/ash" "-c" "echo generation-two > /run/token" ];
    };
    services.added.command = [ "${pkgs.busybox}/bin/sleep" "3600" ];
  });
  initial = make ({ pkgs, ... }: {
    hostname = "nixith-musl-test";
    rootPasswordHash = "";
    networking.enableDHCP = true;
    services = {
      token = {
        type = "scripted";
        environment.NEXT_SYSTEM = toString next.system;
        command = [ "${pkgs.busybox}/bin/ash" "-c" "echo generation-one > /run/token" ];
      };
      first = {
        type = "scripted";
        command = [ "${pkgs.busybox}/bin/ash" "-c" "echo ordered > /run/first" ];
      };
      second = {
        type = "scripted";
        dependsOn = [ "first" ];
        command = [ "${pkgs.busybox}/bin/ash" "-c" "test -f /run/first && echo ordered > /run/second" ];
      };
      failed = {
        type = "scripted";
        command = [ "${pkgs.busybox}/bin/ash" "-c" "exit 7" ];
      };
      removed.command = [ "${pkgs.busybox}/bin/sleep" "3600" ];
      restarting = {
        restart = true;
        command = [ "${pkgs.busybox}/bin/ash" "-c" "n=$(cat /run/restarts 2>/dev/null || echo 0); echo $((n+1)) > /run/restarts; sleep 1; exit 1" ];
      };
    };
  });
  test = p.runCommand "nixithos-musl-integration" {
    nativeBuildInputs = [ p.python3 ];
    requiredSystemFeatures = [ "kvm" ];
  } ''
    mkdir -p "$out"
    python3 ${./musl-vm.py} \
      --qemu ${p.qemu_kvm}/bin/qemu-system-x86_64 \
      --kernel ${initial.kernel}/bzImage --initrd ${initial.initrd}/initrd \
      --next-system ${next.system} --log "$out/serial.log"
    touch "$out/passed"
  '';
  diskTest = p.runCommand "nixithos-musl-disk-integration" {
    nativeBuildInputs = [ p.python3 ];
    requiredSystemFeatures = [ "kvm" ];
  } ''
    mkdir -p "$out"
    cp --sparse=always --reflink=auto ${initial.diskImage}/disk.img disk.img
    chmod u+w disk.img
    python3 ${./musl-vm.py} \
      --qemu ${p.qemu_kvm}/bin/qemu-system-x86_64 \
      --kernel ${initial.kernel}/bzImage --initrd ${initial.initrd}/initrd \
      --disk "$PWD/disk.img" --reboot-check \
      --next-system ${next.system} --log "$out/serial.log"
    touch "$out/passed"
  '';
in
{
  inherit initial next test diskTest;
}
