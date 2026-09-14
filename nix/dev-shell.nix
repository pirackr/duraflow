{ pkgs }:

pkgs.mkShell {
  name = "duraflow-dev";

  packages = (with pkgs.haskellPackages; [
    ghc
    stack
    haskell-language-server
    fourmolu
    ghcid
  ]) ++ [
    pkgs.zlib
  ];

  # Stack builds zlib's Cabal package outside Nix's dependency graph, so expose
  # the pinned native headers and library through standard compiler paths.
  shellHook = ''
    export C_INCLUDE_PATH="${pkgs.zlib.dev}/include''${C_INCLUDE_PATH:+:$C_INCLUDE_PATH}"
    export LIBRARY_PATH="${pkgs.zlib.out}/lib''${LIBRARY_PATH:+:$LIBRARY_PATH}"
  '';
}
