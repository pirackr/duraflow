{ pkgs }:

pkgs.mkShell {
  name = "duraflow-dev";

  packages = with pkgs.haskellPackages; [
    ghc
    stack
    haskell-language-server
    fourmolu
    ghcid
  ];
}
