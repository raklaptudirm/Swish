{
  description = "Swish, a shell whose language is Swift";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    # The interpreter, as source: Swish builds against it by path.
    swiit = {
      url = "github:raklaptudirm/Swiit";
      flake = false;
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      swiit,
    }:
    let
      systems = [
        "aarch64-darwin"
        "x86_64-darwin"
        "aarch64-linux"
        "x86_64-linux"
      ];
      forEachSystem = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
      swish = pkgs: pkgs.callPackage ./nix/package.nix {
        src = self;
        inherit swiit;
      };
    in
    {
      packages = forEachSystem (pkgs: {
        swish = swish pkgs;
        default = swish pkgs;
      });

      overlays.default = final: _: { swish = swish final; };

      homeManagerModules.default = import ./nix/home-manager.nix self;
      darwinModules.default = import ./nix/darwin.nix self;
    };
}
