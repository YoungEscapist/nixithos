# A deliberately standalone system builder. Importing the NixOS module tree
# would add Bash and GNU tools through activation and stage-1 scripts.
{
  pkgs,
  hostPkgs,
  config ? { },
  runtime,
  control,
  nativeNix ? null,
}:
let
  inherit (hostPkgs) lib;
  allowed = [
    "hostname" "packages" "kernel" "kernelModules" "console"
    "rootPasswordHash" "networking" "services"
  ];
  unknown = lib.subtractLists allowed (builtins.attrNames config);
  hostname = config.hostname or "nixith-musl";
  console = config.console or (if hostPkgs.stdenv.hostPlatform.isAarch64 then "ttyAMA0" else "ttyS0");
  rootPasswordHash = config.rootPasswordHash or "!";
  networking = config.networking or { };
  networkUnknown = lib.subtractLists [ "enableDHCP" "interface" ] (builtins.attrNames networking);
  interface = networking.interface or "eth0";
  kernel = config.kernel or hostPkgs.linux;
  kernelModules = config.kernelModules or [ "virtio_pci" "virtio_net" "virtio_blk" "virtio_console" "ext4" "af_packet" ];
  kernelImage = "${kernel}/${kernel.target or hostPkgs.stdenv.hostPlatform.linux-kernel.target}";
  busybox = pkgs.busybox;
  dinit = pkgs.dinit;
  packages = (config.packages or [ ]) ++ lib.optionals (nativeNix != null) [ nativeNix hostPkgs.cacert ];
  modules = hostPkgs.makeModulesClosure {
    kernel = kernel.modules or kernel;
    firmware = hostPkgs.emptyDirectory;
    rootModules = kernelModules;
    allowMissing = false;
  };
  # Decompress modules during the build so BusyBox modprobe needs no external
  # decompressor or dependency on the full kernel output in the target closure.
  moduleTree = hostPkgs.runCommand "nixith-musl-modules" {
    nativeBuildInputs = [ hostPkgs.kmod hostPkgs.xz hostPkgs.zstd ];
  } ''
    cp -a ${modules}/lib $out
    chmod -R u+w $out
    find "$out" -name '*.ko.xz' -exec unxz '{}' \;
    find "$out" -name '*.ko.zst' -exec unzstd --rm '{}' \;
    for version in "$out"/modules/*; do
      mkdir -p "$TMPDIR/root/lib"
      ln -s "$out/modules" "$TMPDIR/root/lib/modules"
      depmod -b "$TMPDIR/root" "$(basename "$version")"
      rm "$TMPDIR/root/lib/modules"
    done
  '';
  boot = hostPkgs.writeText "nixith-musl-init" (
    lib.replaceStrings
      [ "@system@" "@kernelModules@" "@networkSetup@" "@dinit@" ]
      [ "@NIXITH_SYSTEM@"
        (lib.escapeShellArgs kernelModules)
        (lib.optionalString (networking.enableDHCP or false) ''
          ip link set ${lib.escapeShellArg interface} up || fail 'cannot bring up network interface'
          udhcpc -b -i ${lib.escapeShellArg interface} -s /etc/udhcpc.script || fail 'DHCP client could not start'
        '')
        (toString dinit)
      ]
      (builtins.readFile ./boot.sh)
  );
  auditInputs = hostPkgs.closureInfo {
    rootPaths = [ busybox dinit runtime.package runtime.services control moduleTree ] ++ packages;
  };
  system = hostPkgs.runCommand "nixithos-musl-system" {
    preferLocalBuild = true;
    passthru = { inherit busybox dinit kernel; };
  } ''
    mkdir -p "$out"/{bin,etc,proc,sys,dev,run/lock,tmp,root,home,mnt,nix/store,nix/var/nix/profiles,var/lib,var/log,var/tmp,lib,usr}
    chmod 1777 "$out/tmp" "$out/var/tmp"
    for program in ${busybox}/bin/*; do
      ln -s "$program" "$out/bin/$(basename "$program")"
    done
    for package in ${lib.escapeShellArgs (map toString packages)}; do
      for program in "$package"/bin/*; do
        [ -e "$program" ] || continue
        ln -s "$program" "$out/bin/$(basename "$program")"
      done
    done
    for program in ${runtime.package}/bin/* ${control}/bin/*; do
      [ -e "$program" ] || continue
      ln -sf "$program" "$out/bin/$(basename "$program")"
    done
    ln -sf ${dinit}/bin/dinit "$out/bin/dinit"
    ln -sf ${dinit}/bin/dinitctl "$out/bin/dinitctl"
    # dinit's helpers request an orderly PID-1 shutdown. BusyBox -f remains
    # available for emergency use as `busybox poweroff -f`.
    for command in poweroff reboot halt shutdown; do
      if [ -e ${dinit}/bin/"$command" ]; then
        ln -sf ${dinit}/bin/"$command" "$out/bin/$command"
      fi
    done
    ln -s bin "$out/sbin"
    ln -s /bin "$out/usr/bin"
    ln -s /bin "$out/usr/sbin"
    ln -s /run "$out/var/run"
    ln -s /run/lock "$out/var/lock"
    ln -s "$out" "$out/nix/var/nix/profiles/system"
    ln -s ${runtime.services}/etc/dinit.d "$out/etc/dinit.d"
    mkdir -p "$out/etc/unit-runtime"
    ln -s ${runtime.services}/etc/unit-runtime/services "$out/etc/unit-runtime/services"
    cp -a ${moduleTree}/modules "$out/lib/modules"
    cp ${boot} "$out/init"
    substituteInPlace "$out/init" --replace-fail '@NIXITH_SYSTEM@' "$out"
    chmod 755 "$out/init"
    printf '%s\n' ${lib.escapeShellArg hostname} > "$out/etc/hostname"
    printf '%s\n' 'root:x:0:0:root:/root:/bin/ash' 'nobody:x:65534:65534:nobody:/var/empty:/bin/false' > "$out/etc/passwd"
    printf '%s\n' ${lib.escapeShellArg "root:${rootPasswordHash}:0:0:99999:7:::"} 'nobody:!:0:0:99999:7:::' > "$out/etc/shadow"
    chmod 600 "$out/etc/shadow"
    printf '%s\n' 'root:x:0:' 'tty:x:5:' 'nobody:x:65534:' > "$out/etc/group"
    printf '%s\n' '/bin/sh' '/bin/ash' > "$out/etc/shells"
    printf '%s\n' '127.0.0.1 localhost ${hostname}' '::1 localhost' > "$out/etc/hosts"
    printf '%s\n' 'hosts: files dns' 'passwd: files' 'group: files' > "$out/etc/nsswitch.conf"
    : > "$out/etc/fstab"
    printf '%s\n' 'nameserver 10.0.2.3' > "$out/etc/resolv.conf"
    printf '%s\n' 'NixithOS musl / BusyBox' > "$out/etc/issue"
    printf '%s\n' 'NAME=NixithOS' 'ID=nixithos' 'VARIANT=musl' 'VARIANT_ID=musl' > "$out/etc/os-release"
    printf '%s\n' '1' > "$out/etc/nixith-musl"
    printf '%s\n' 'export PATH=/run/current-system/bin:/bin:/sbin' 'export SHELL=/bin/ash' 'export PAGER=less' > "$out/etc/profile"
    ${lib.optionalString (nativeNix != null) ''
      mkdir -p "$out/etc/nix" "$out/etc/ssl/certs"
      ln -s ${hostPkgs.cacert}/etc/ssl/certs/ca-bundle.crt "$out/etc/ssl/certs/ca-certificates.crt"
      cat > "$out/etc/nix/nix.conf" <<'NIXCONF'
      build-users-group =
      experimental-features = nix-command flakes
      sandbox = true
      ssl-cert-file = /etc/ssl/certs/ca-certificates.crt
      NIXCONF
    ''}
    cat > "$out/etc/udhcpc.script" <<'EOF'
    #!/bin/sh
    case "$1" in
      deconfig) ip address flush dev "$interface" ;;
      bound|renew)
        ip route del default dev "$interface" 2>/dev/null || :
        ifconfig "$interface" "$ip" netmask "''${subnet:-255.255.255.0}"
        for gateway in $router; do ip route add default via "$gateway" dev "$interface"; break; done
        : > /etc/resolv.conf
        for server in $dns; do echo "nameserver $server" >> /etc/resolv.conf; done
        ;;
    esac
    EOF
    chmod 755 "$out/etc/udhcpc.script"
    if ! ${hostPkgs.python3}/bin/python3 ${../scripts/audit-musl-closure.py} --paths ${auditInputs}/store-paths --system-root "$out" --json > "$TMPDIR/system-audit.json"; then
      cat "$TMPDIR/system-audit.json"
      exit 1
    fi
  '';
  closure = hostPkgs.closureInfo { rootPaths = [ system ]; };
  rootfs = hostPkgs.runCommand "nixithos-musl-rootfs" { preferLocalBuild = true; } ''
    mkdir -p "$out/nix/store"
    while IFS= read -r path; do
      cp -a "$path" "$out/nix/store/"
    done < ${closure}/store-paths
    cp -a ${system}/. "$out/"
    chmod u+w "$out" "$out/etc" "$out/nix" "$out/nix/store"
    ${lib.optionalString (nativeNix != null) ''
      chmod u+w "$out/etc/nix"
      cp ${closure}/registration "$out/etc/nix/registration"
    ''}
    if ! ${hostPkgs.python3}/bin/python3 ${../scripts/audit-musl-closure.py} --rootfs "$out" --json > "$TMPDIR/audit.json"; then
      cat "$TMPDIR/audit.json"
      exit 1
    fi
  '';
  initrd = hostPkgs.runCommand "nixithos-musl-initrd" {
    nativeBuildInputs = [ hostPkgs.cpio hostPkgs.gzip ];
    preferLocalBuild = true;
  } ''
    mkdir -p "$out"
    cd ${rootfs}
    find . -print0 | sort -z | cpio --null --create --format=newc --reproducible --owner=0:0 | gzip -n -9 > "$out/initrd"
  '';
  diskImage = hostPkgs.runCommand "nixithos-musl-ext4" {
    nativeBuildInputs = [ hostPkgs.e2fsprogs ];
    preferLocalBuild = true;
  } ''
    mkdir -p "$out"
    size=$(du -sm ${rootfs} | cut -f1)
    size=$((size + 256))
    [ "$size" -ge 512 ] || size=512
    truncate -s "''${size}M" "$out/disk.img"
    mkfs.ext4 -q -F -L nixithos-musl -d ${rootfs} "$out/disk.img"
  '';
  bootDiskImage = hostPkgs.runCommand "nixithos-musl-boot-disk" {
    nativeBuildInputs = [ hostPkgs.util-linux hostPkgs.dosfstools hostPkgs.mtools hostPkgs.limine ];
    preferLocalBuild = true;
  } ''
    mkdir -p "$out"
    root_sectors=$(($(stat -c %s ${diskImage}/disk.img) / 512))
    # Leave room for the complete initramfs, including optional native Nix.
    esp_mib=$((($(stat -c %s ${kernelImage}) + $(stat -c %s ${initrd}/initrd)) / 1048576 + 32))
    [ "$esp_mib" -ge 64 ] || esp_mib=64
    # 1 MiB alignment, FAT EFI system partition, then the populated root.
    esp_start=2048
    esp_sectors=$((esp_mib * 2048))
    root_start=$((esp_start + esp_sectors))
    bios_start=$((root_start + root_sectors))
    truncate -s "$(((bios_start + 4096) * 512))" "$out/disk.img"
    sfdisk "$out/disk.img" <<EOF
    label: gpt
    start=$esp_start, size=$esp_sectors, type=U
    start=$root_start, size=$root_sectors, type=L
    start=$bios_start, size=2048, type=21686148-6449-6E6F-744E-656564454649
    EOF
    truncate -s "''${esp_mib}M" esp.img
    mkfs.vfat -F 32 -n NIXITHBOOT esp.img
    mmd -i esp.img ::/EFI ::/EFI/BOOT
    mcopy -i esp.img ${hostPkgs.limine}/share/limine/${if hostPkgs.stdenv.hostPlatform.isx86_64 then "BOOTX64.EFI" else "BOOTAA64.EFI"} ::/EFI/BOOT/
    ${lib.optionalString hostPkgs.stdenv.hostPlatform.isx86_64 ''
      mcopy -i esp.img ${hostPkgs.limine}/share/limine/limine-bios.sys ::/
    ''}
    mcopy -i esp.img ${kernelImage} ::/vmlinuz
    mcopy -i esp.img ${initrd}/initrd ::/initrd
    cat > limine.conf <<'EOF'
    timeout: 0
    serial: yes

    /NixithOS musl
    protocol: linux
    kernel_path: boot():///vmlinuz
    module_path: boot():///initrd
    cmdline: console=${console} rdinit=/init root=LABEL=nixithos-musl rootfstype=ext4 panic=1
    EOF
    mcopy -i esp.img limine.conf ::/limine.conf
    dd if=esp.img of="$out/disk.img" bs=512 seek="$esp_start" conv=notrunc,sparse status=none
    dd if=${diskImage}/disk.img of="$out/disk.img" bs=512 seek="$root_start" conv=notrunc,sparse status=none
    ${lib.optionalString hostPkgs.stdenv.hostPlatform.isx86_64 ''
      limine bios-install "$out/disk.img"
    ''}
  '';
  qemu = "${hostPkgs.qemu}/bin/qemu-system-${if hostPkgs.stdenv.hostPlatform.isx86_64 then "x86_64" else "aarch64"}";
  machineArgs = lib.optionalString hostPkgs.stdenv.hostPlatform.isAarch64 "-machine virt -cpu cortex-a72";
  vm = hostPkgs.writeShellScriptBin "run-nixithos-musl-vm" ''
    exec ${qemu} ${machineArgs} \
      -m 512 -smp 2 -nographic -no-reboot \
      -kernel ${kernelImage} -initrd ${initrd}/initrd \
      -append ${lib.escapeShellArg "console=${console} rdinit=/init panic=1"} \
      -netdev user,id=net0 -device virtio-net-pci,netdev=net0 "$@"
  '';
  diskVm = hostPkgs.writeShellScriptBin "run-nixithos-musl-disk-vm" ''
    image=''${NIXITH_DISK:-./nixithos-musl.img}
    if [ ! -e "$image" ]; then
      ${hostPkgs.coreutils}/bin/cp --sparse=always ${diskImage}/disk.img "$image"
      chmod u+w "$image"
    fi
    exec ${qemu} ${machineArgs} \
      -m 512 -smp 2 -nographic -no-reboot \
      -kernel ${kernelImage} -initrd ${initrd}/initrd \
      -append ${lib.escapeShellArg "console=${console} rdinit=/init root=/dev/vda rootfstype=ext4 panic=1"} \
      -drive file="$image",format=raw,if=virtio \
      -netdev user,id=net0 -device virtio-net-pci,netdev=net0 "$@"
  '';
  bootVm = hostPkgs.writeShellScriptBin "run-nixithos-musl-boot-vm" ''
    image=''${NIXITH_DISK:-./nixithos-musl-boot.img}
    if [ ! -e "$image" ]; then
      ${hostPkgs.coreutils}/bin/cp --sparse=always ${bootDiskImage}/disk.img "$image"
      chmod u+w "$image"
    fi
    exec ${qemu} ${machineArgs} ${lib.optionalString hostPkgs.stdenv.hostPlatform.isAarch64 "-bios ${hostPkgs.OVMF.firmware}"} \
      -m 512 -smp 2 -nographic -no-reboot \
      -drive file="$image",format=raw,if=virtio \
      -netdev user,id=net0 -device virtio-net-pci,netdev=net0 "$@"
  '';
in
assert lib.assertMsg (unknown == [ ]) "musl system: unsupported options: ${lib.concatStringsSep ", " unknown}";
assert lib.assertMsg (networkUnknown == [ ]) "musl networking: unsupported options: ${lib.concatStringsSep ", " networkUnknown}";
assert lib.assertMsg (builtins.match "[a-zA-Z0-9][a-zA-Z0-9.-]*" hostname != null) "musl hostname contains unsupported characters";
assert lib.assertMsg (builtins.match "[a-zA-Z0-9_-]+" console != null) "musl console must name one device";
assert lib.assertMsg (builtins.match "[a-zA-Z0-9_.:-]+" interface != null) "musl network interface contains unsupported characters";
assert lib.assertMsg (!(lib.hasInfix ":" rootPasswordHash || lib.hasInfix "\n" rootPasswordHash)) "musl rootPasswordHash must be a single crypt hash";
{
  inherit system rootfs initrd diskImage bootDiskImage kernel kernelImage vm diskVm bootVm closure busybox dinit;
  toplevel = system;
}
