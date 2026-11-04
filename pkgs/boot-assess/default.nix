# nixith-boot-assess: a generation that was just installed to boot from is on
# trial until it has booted; see the script and
# ../../modules/system/boot-assessment.nix.
{
  lib,
  replaceVarsWith,
  bash,
  coreutils,
  gnugrep,
  gnused,
  gawk,
  util-linux,
  # which boot loader: systemd-boot, grub, limine, or none
  loader ? "none",
  tries ? 3,
  # system units (S6 names: foo.service) the boot has to have brought up
  required ? [ ],
  # systemd-boot: where loader/entries is; grub: boot.loader.grub's path;
  # limine: the ESP
  bootDir ? "/boot",
  espDir ? "/boot",
  efiSupport ? false,
  grubPackage ? null,
  efibootmgr ? null,
}:

replaceVarsWith {
  name = "nixith-boot-assess";
  src = ./boot-assess.sh;
  dir = "bin";
  isExecutable = true;

  replacements = {
    shell = "${bash}/bin/bash";
    path = lib.makeBinPath [
      coreutils
      gnugrep
      gnused
      gawk
      util-linux
    ];
    inherit loader bootDir espDir;
    tries = toString tries;
    required = lib.escapeShellArgs required;
    efiSupport = if efiSupport then "1" else "''";
    grubEditenv = if grubPackage == null then "''" else "${grubPackage}/bin/grub-editenv";
    efibootmgr = if efibootmgr == null then "''" else "${efibootmgr}/bin/efibootmgr";
  };

  postInstall = ''
    ${bash}/bin/bash -n $target
  '';

  meta = {
    description = "Puts a new generation on trial until it has booted, and goes back if it does not";
    mainProgram = "nixith-boot-assess";
    platforms = lib.platforms.linux;
  };
}
