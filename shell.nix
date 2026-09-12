# Legacy nix-shell uses the same nixpkgs pin and tools as nix develop.
{ system ? builtins.currentSystem }:

let
  lock = builtins.fromJSON (builtins.readFile ./flake.lock);
  source = lock.nodes.nixpkgs.locked;
  nixpkgs = builtins.fetchTarball {
    url = "https://codeload.github.com/${source.owner}/${source.repo}/tar.gz/${source.rev}";
    sha256 = source.narHash;
  };
  pkgs = import nixpkgs { inherit system; };
in
import ./nix/dev-shell.nix { inherit pkgs; }
