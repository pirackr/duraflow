# Task 1 report: pinned dependency closure

## Outcome

Pinned the project to `lts-24.59`, generated and checked in Stack's content lock, added the approved core dependency family with snapshot-compatible bounds, and exposed pinned Nix zlib headers/libraries to ordinary Stack commands. No runtime code, plan text, plan checkbox, or `flake.lock` was changed.

## Changed files

- `stack.yaml` — replaced the compiler-only resolver with `lts-24.59` while preserving `system-ghc: true`, `install-ghc: false`, `compiler-check: match-exact`, `notify-if-nix-on-path: false`, and `nix.enable: false`.
- `stack.yaml.lock` — generated Stack snapshot lock with the approved SHA256 and byte size.
- `duraflow-core/duraflow.cabal` — added `aeson`, `bytestring`, `directory`, `filepath`, `filelock`, `text`, and `unix` to the library and internal test suite with snapshot-selected caret bounds. Weather-only packages were not added to the core library.
- `nix/dev-shell.nix` — added zlib from the already locked nixpkgs input and exported its development include and output library paths via `C_INCLUDE_PATH` and `LIBRARY_PATH`, which Stack's compiler/configure subprocesses consume.
- `.superpowers/sdd/2026-09-14-weather-workflow-mvp/task-1-report.md` — this report.

## Baseline evidence

Before edits:

```sh
nix develop --no-write-lock-file --command ghc --numeric-version
```

Exit 0; stdout:

```text
9.10.3
```

Nix also emitted an ignorable concurrent eval-cache warning on stderr.

```sh
nix develop --no-write-lock-file --command stack test
```

Exit 0. Stack built with GHC 9.10.3 and reported:

```text
duraflow> Test suite duraflow-test passed
```

## Snapshot and selected versions

Resolver: `lts-24.59`

Generated lock entry:

```text
sha256: 0f728e30e843d7f00460ad56858b995a3b227fca683659c7df9f2fc3988a3ce1
size: 732465
url: https://raw.githubusercontent.com/commercialhaskell/stackage-snapshots/master/lts/24/59.yaml
```

Resolved package versions:

| Package | Version |
|---|---:|
| GHC | 9.10.3 |
| base | 4.20.2.0 |
| aeson | 2.2.5.1 |
| bytestring | 0.12.2.0 |
| directory | 1.3.8.5 |
| filepath | 1.5.4.0 |
| filelock | 0.1.1.9 |
| text | 2.1.3 |
| unix | 2.8.7.0 |
| http-client | 0.7.19 |
| http-client-tls | 0.3.6.4 |
| time | 1.12.2 |
| Haskell zlib | 0.7.1.1 |
| native zlib | 1.3.2 |

The first eight non-weather libraries are direct core and internal-test dependencies. `http-client`, `http-client-tls`, and `time` remain available to the external weather application without creating a core-to-weather dependency.

## Required validation

```sh
nix develop --no-write-lock-file --command stack build --test --no-run-tests
```

Exit 0. Configured, compiled, linked, copied, and registered the local `duraflow-0.1.0.0` library and `duraflow-test` with `ghc-9.10.3`; tests were intentionally not run.

```sh
nix develop --no-write-lock-file --command stack build http-client http-client-tls
```

Exit 0 with no manual include/library flags.

The required smoke file `/tmp/duraflow-dependency-smoke.hs` contained imports of `Duraflow`, `Data.Aeson`, `System.FileLock`, `System.Posix.Unistd`, `Network.HTTP.Client`, `Network.HTTP.Client.TLS`, and `Data.Time`, plus:

```haskell
main = putStrLn "dependency closure loaded"
```

```sh
nix develop --no-write-lock-file --command stack runghc --package duraflow --package aeson --package filelock --package unix --package http-client --package http-client-tls --package time -- /tmp/duraflow-dependency-smoke.hs
```

Exit 0. Script stdout was exactly:

```text
dependency closure loaded
```

Stack emitted a non-fatal `No latest package revision found for aeson` warning on stderr; resolution remained pinned by the snapshot and lock file.

## Clean native dependency proof

To ensure the successful HTTP build did not merely reuse the planning worker's package cache, I rebuilt the HTTP/TLS closure under a fresh, owner-created Stack root and separate relative work directory:

```sh
rm -rf /tmp/duraflow-task1-stack-root .stack-work-task1
mkdir -m 700 /tmp/duraflow-task1-stack-root
nix develop --no-write-lock-file --command env STACK_ROOT=/tmp/duraflow-task1-stack-root stack --work-dir .stack-work-task1 build http-client http-client-tls
```

Exit 0; Stack completed 61 actions, including configuring/building the zlib-dependent closure and `http-client-0.7.19` and `http-client-tls-0.3.6.4`, with GHC 9.10.3 and no manual native flags. Temporary validation directories were then removed.

The shared shell exports were verified with:

```sh
nix develop --no-write-lock-file --command bash -c 'printf "ghc="; ghc --numeric-version; printf "zlib="; pkg-config --modversion zlib; printf "C_INCLUDE_PATH=%s\nLIBRARY_PATH=%s\n" "$C_INCLUDE_PATH" "$LIBRARY_PATH"'
```

Exit 0:

```text
ghc=9.10.3
zlib=1.3.2
C_INCLUDE_PATH=/nix/store/ydgdz8pf2in3rlb5agwkgr76vfrdf2s5-zlib-1.3.2-dev/include
LIBRARY_PATH=/nix/store/78x9i5x1wpqw4kq0h39b8f35abcv156h-zlib-1.3.2/lib
```

Post-change suite:

```sh
nix develop --no-write-lock-file --command stack test
```

Exit 0; `duraflow-test` passed.

Final hygiene:

```sh
git diff --check
```

Exit 0 with no output.

Two preliminary attempts to isolate Stack did not build anything: Stack rejected an absolute `--work-dir`, then rejected creating a missing Stack root directly beneath `/tmp`. Creating the owner-only root and using a relative work directory produced the successful clean build above. Neither preliminary command changed tracked project files.

## Self-review

- Confirmed the lock hash and size match the brief verbatim.
- Confirmed all existing Stack/Nix compiler ownership and exact-match settings remain unchanged.
- Confirmed GHC remains exactly 9.10.3 and `flake.lock` is unchanged.
- Confirmed core and internal test dependencies contain only the approved core family; HTTP, TLS, and time were not introduced into the core package.
- Confirmed ordinary required commands need no ad hoc `--extra-include-dirs` or `--extra-lib-dirs` flags.
- Confirmed no runtime source or implementation plan was modified.
- Reviewed the final diff and ran whitespace validation.

## Concerns

None. The Stack runghc warning about an unavailable latest Hackage revision is informational and does not weaken snapshot/content pinning or module loading.
