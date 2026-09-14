# Core and workflow workspace split

## Scope and approval

The user approved reorganizing the existing scaffold into `duraflow-core/` and `workflows/`, with pull requests for the resulting work. This document records the structural design for written review before implementation. Runtime implementation remains a separate task.

The checkout currently contains an empty Haskell library, empty executable and test entrypoints, shared Stack and Nix configuration, and an illustrative weather workflow. The sketch is not runnable.

## Package and directory boundaries

Keep one Cabal package, named `duraflow`, inside `duraflow-core/`. Keep its public module named `Duraflow`. Directory naming does not require a package or API rename.

The proposed layout is:

```text
README.md
stack.yaml
flake.nix
flake.lock
shell.nix
nix/
.github/workflows/ci.yml
duraflow-core/
  duraflow.cabal
  README.md
  src/
    Duraflow.hs
  test/
    Main.hs
workflows/
  README.md
  WeatherWorkflow.example.hs
docs/superpowers/specs/
  2026-09-14-core-workflows-split-design.md
```

Move the existing Cabal file, library source, and test source into the core package. Remove the empty `app/Main.hs` and its executable component. Add a package-local README so the Cabal `extra-source-files: README.md` declaration remains valid. Preserve the empty library and placeholder test behavior rather than introducing runtime features during the move.

Move `WeatherWorkflow.example.hs` into `workflows/` without changing its proposed API or presenting it as runnable. Add a short workflow README describing the sketch and local development boundary. It is not a Cabal package and is not part of the build.

## Workflows can live anywhere

`workflows/` is a convenient collection of application examples, not a required discovery directory or runtime convention. Real workflows may live elsewhere on disk or in independent repositories. They depend on a compatible Duraflow library; the core never imports, scans for, or registers application workflows.

Future runtime configuration must permit an explicit execution state location independent of the workflow source directory. Moving a script does not itself move execution state or grant permission to resume a different execution. This split documents that boundary but adds no state API.

For development, project-aware Stack commands can use the local core package. Standalone `stack script` ignores project-level `stack.yaml`, so a truly standalone script needs its own compatible snapshot and resolvable, pinned Duraflow dependency. This change does not claim that the current sketch can be launched either way.

## Workspace and build configuration

Keep Stack, Nix, CI, and the workspace README at the repository root. Change the Stack package entry from the root directory to `duraflow-core`.

Preserve the compiler pin and Nix toolchain ownership. Update the root README layout and formatting paths. Update CI caching to include the nested package build directory; keep root build and test commands working. Review the Cabal package description so it remains accurate after the empty executable is removed.

Do not modify unrelated staged files, existing design PDFs, Python bytecode, or the user's pending ignore-file changes. Existing historical design documents are not rewritten as part of this structural change.

## Future components

Do not create `duraflow-loop`, `duraflow-ticket`, or `duraflow-orchestrator` now. A future component can be a sibling package depending on the core, with its own responsibilities for triggering, scheduling, or supervision. None of those capabilities becomes a requirement of the library merely because the workspace can host them.

## Validation

Build all remaining Cabal components and run the existing test suite with the pinned Nix and Stack environment. These checks establish that the scaffold still builds, not that durability or resume works.

Verify that Cabal source packaging can resolve the package-local README and sources. Inspect the diff for stale paths, unintended application imports in the core, accidental inclusion of the weather sketch in the build, and unrelated changes.

## Delivery

Use a conventional commit for the approved structural change and a focused pull request. This is one cohesive restructuring change, so one implementation PR is sufficient. Do not invent additional PRs for unimplemented runtime features. Use `gh` for GitHub operations.

The next gate is user review of this written specification. After approval, create the implementation plan using the writing-plans skill, then perform the restructuring and validation.
