{
  description = "NixithOS: NixOS on s6-linux-init and s6-rc instead of systemd";

  # nixos-26.05; keep in step with lib/nixpkgs.json
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/7993f34ee47e28a3d607a525aadc6c94b73be728";

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
      });

      checks = forAllSystems (system: (tree system).tests);
    };
}
