{ nixpkgs ? import ../lib/nixpkgs.nix, system ? builtins.currentSystem }:
let
  p = import nixpkgs { inherit system; };
  machine = import ../musl {
    inherit nixpkgs system;
    withNix = true;
    configuration = {
      hostname = "nixith-musl-native";
      rootPasswordHash = "";
      networking.enableDHCP = true;
    };
  };
  test = p.runCommand "nixithos-musl-native-nix-integration" {
    nativeBuildInputs = [ p.python3 ];
    requiredSystemFeatures = [ "kvm" ];
  } ''
    mkdir -p "$out"
    cp --sparse=always --reflink=auto ${machine.diskImage}/disk.img disk.img
    chmod u+w disk.img
    python3 ${./musl-vm.py} \
      --qemu ${p.qemu_kvm}/bin/qemu-system-x86_64 \
      --kernel ${machine.kernel}/bzImage --initrd ${machine.initrd}/initrd \
      --disk "$PWD/disk.img" --reboot-check --native-nix \
      --busybox-store ${machine.busybox} --log "$out/serial.log"
    touch "$out/passed"
  '';
in { inherit machine test; }
