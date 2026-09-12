# Duraflow v2

Haskell project setup only. The library is empty and the executable/test
entrypoints are placeholders. No scheduler, worker, persistence, or pi
integration is implemented. The Python demo has been removed.

## Development

Both shells use the nixpkgs revision in `flake.lock` and share the tool list
in `nix/dev-shell.nix`: GHC, Stack, Haskell Language Server, Fourmolu,
and ghcid. Linux x86_64 and aarch64 shell definitions are provided.

```sh
nix develop path:.
# Or, without using flakes:
nix-shell
```

`path:.` includes new, untracked scaffold files. Once the Nix files are
tracked by Git, plain `nix develop` works too.

Inside either shell:

```sh
stack build
stack test
stack ghci duraflow:lib
fourmolu --mode inplace src/Duraflow.hs app/Main.hs test/Main.hs
```

`stack.yaml` uses a compiler-only resolver because the scaffold depends only
on `base`. Stack uses Nix's GHC, checks its exact version, and never installs
a second compiler. When adding dependencies, choose a compatible Stackage
snapshot or pin extra dependencies. The test suite is an empty placeholder,
not a test of workflow behavior.

Update the shared nixpkgs pin with `nix flake update --flake path:.`, then keep
the compiler version in `stack.yaml` aligned with the new shell's GHC.

## Layout

```text
app/Main.hs        empty executable entrypoint
src/Duraflow.hs     empty public library module
test/Main.hs       empty test entrypoint
duraflow.cabal     package/component definitions
stack.yaml        Stack workspace and compiler configuration
flake.nix         flake development shell
flake.lock        pinned nixpkgs
shell.nix         legacy development shell using the same pin
nix/dev-shell.nix  shared development tools
```

The Nix setup provides a development shell only; package derivations and
application features can be added later. No project license has been chosen
(`license: NONE` in Cabal).
