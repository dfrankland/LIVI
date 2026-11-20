{
  description = "LIVI - Linux In-Vehicle Infotainment (Nix package and NixOS module)";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";
    # LIVI tracks the latest stable Rust (rust-toolchain.toml), which runs ahead
    # of what a NixOS release ships.
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = {
    self,
    nixpkgs,
    rust-overlay,
  }: let
    systems = ["x86_64-linux" "aarch64-linux"];
    forAll = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

    mkLivi = pkgs: let
      toolchain = (rust-overlay.lib.mkRustBin {} pkgs).fromRustupToolchainFile ./rust-toolchain.toml;
    in
      pkgs.callPackage ./nix/package.nix {
        rustPlatform = pkgs.makeRustPlatform {
          cargo = toolchain;
          rustc = toolchain;
        };
      };
  in {
    packages = forAll (pkgs: rec {
      livi = mkLivi pkgs;
      default = livi;
    });

    overlays.default = final: _prev: {
      livi = mkLivi final;
    };

    nixosModules = rec {
      livi = {
        imports = [./nix/module.nix];
        nixpkgs.overlays = [self.overlays.default];
      };
      default = livi;
    };

    formatter = forAll (pkgs: pkgs.alejandra);
  };
}
