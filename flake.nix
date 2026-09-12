{
  description = "Duraflow Haskell development environment";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { nixpkgs, ... }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
    in
    {
      devShells = nixpkgs.lib.genAttrs systems (system: {
        default = import ./nix/dev-shell.nix {
          pkgs = import nixpkgs { inherit system; };
        };
      });
    };
}
