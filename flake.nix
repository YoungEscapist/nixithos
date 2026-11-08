{
  description = "NixithOS: NixOS without systemd, on s6, dinit, runit or OpenRC";

  # nixos-26.05; keep in step with lib/nixpkgs.json
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/7dcdd87373d72e7a2173e4db02e20d3d7f495cfd";

  outputs =
    { self, nixpkgs }:
    let
      inherit (nixpkgs) lib;
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = lib.genAttrs systems;
      tree = system: import ./. {
        nixpkgs = nixpkgs.outPath;
        inherit system;
      };
    in
    {
      # The counterpart of `nixpkgs.lib.nixosSystem`:
      #
      #   nixosConfigurations.box = nixithos.lib.system {
      #     modules = [ ./configuration.nix ];
      #   };
      lib.system =
        args:
        import ./lib/eval-config.nix (
          {
            nixpkgs = nixpkgs.outPath;
            inherit lib;
            system = null; # set nixpkgs.hostPlatform in the configuration
          }
          // args
        );

      lib.muslSystem = args: import ./musl ({ nixpkgs = nixpkgs.outPath; } // args);

      # ... or the same as a module, for a plain `nixpkgs.lib.nixosSystem`
      # (the nixpkgs it is given has to be the revision this tree was written
      # for, or at least one where `modules/module-list.nix` is the same):
      #
      #   nixpkgs.lib.nixosSystem {
      #     modules = [ nixithos.nixosModules.default ./configuration.nix ];
      #   };
      nixosModules.default = import ./modules/default.nix;
      nixosModules.s6 = self.nixosModules.default;

      overlays.default = import ./pkgs/overlay.nix;
      overlays.no-systemd = import ./pkgs/no-systemd.nix;

      nixosConfigurations.vm = self.lib.system {
        modules = [
          ./tests/configs/vm.nix
          { nixpkgs.hostPlatform = "x86_64-linux"; }
        ];
      };

      packages = forAllSystems (system: {
        vm = (tree system).configs.vm.vm;
        musl-initrd = (tree system).musl.initrd;
        musl-disk = (tree system).musl.diskImage;
        musl-boot-disk = (tree system).musl.bootDiskImage;
        musl-vm = (tree system).musl.vm;
        musl-boot-vm = (tree system).musl.bootVm;
        musl-dinit = (tree system).musl.dinit;
      });

      checks = forAllSystems (system: (tree system).tests);
    };
}
