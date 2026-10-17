# A set of everyday tools, for the images and for systems that want it:
#
#   nixithos.utilities.enable = true;
{
  config,
  lib,
  pkgs,
  ...
}:
{
  options.nixithos.utilities.enable = lib.mkEnableOption "a set of everyday command-line tools";

  config = lib.mkIf config.nixithos.utilities.enable {
    environment.systemPackages = with pkgs; [
      # files and text
      git
      vim
      neovim
      nano
      tmux
      htop
      btop
      tree
      file
      ripgrep
      fd
      jq
      bat
      zip
      unzip
      p7zip
      rsync
      # network
      curl
      wget
      dnsutils
      iproute2
      nmap
      # hardware and disks
      pciutils
      usbutils
      lshw
      smartmontools
      gptfdisk
      parted
      dosfstools
      ntfs3g
      exfatprogs
    ];
  };
}
