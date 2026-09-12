{ pkgs }:

pkgs.mkShell {
  name = "duraflow-dev";

  packages = [ pkgs.python3 ] ++ (with pkgs.haskellPackages; [
    ghc
    stack
    haskell-language-server
    fourmolu
    ghcid
  ]);
}
