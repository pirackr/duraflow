# Core and Workflows Split Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Separate the reusable Haskell scaffold into `duraflow-core/` and the illustrative weather application into `workflows/`, preserving the pinned workspace build.

**Architecture:** The repository root remains the Stack and Nix workspace. The nested Cabal package remains named `duraflow` and exposes `Duraflow`; application examples remain outside its build and can live anywhere. No runtime feature or future orchestrator package is introduced.

**Tech Stack:** Haskell GHC 9.10.3, Stack, Cabal, pinned Nix, GitHub Actions, Python 3 for structural verification.

**Spec:** `docs/superpowers/specs/2026-09-14-core-workflows-split-design.md`

## Global Constraints

- Keep one Cabal package, named `duraflow`, inside `duraflow-core/`. Keep its public module named `Duraflow`.
- Keep Stack, Nix, CI, and the workspace README at the repository root.
- Preserve the compiler pin and Nix toolchain ownership.
- The core never imports, scans for, or registers application workflows.
- The sketch is not runnable.
- Do not modify unrelated staged files, existing design PDFs, Python bytecode, or the user's pending ignore-file changes.
- Do not create `duraflow-loop`, `duraflow-ticket`, or `duraflow-orchestrator` now.
- Use `gh` for GitHub operations.
- Baseline test evidence: `nix develop path:. --command stack test` passed on the original scaffold. The test suite remains a placeholder, not durability coverage.

---

### Task 1: Extract the library package and application examples

**Files:**

- Move unchanged: `src/Duraflow.hs` to `duraflow-core/src/Duraflow.hs`.
- Move unchanged: `test/Main.hs` to `duraflow-core/test/Main.hs`.
- Move and modify: `duraflow.cabal` to `duraflow-core/duraflow.cabal`.
- Remove: the empty `app/Main.hs`.
- Move unchanged: `WeatherWorkflow.example.hs` to `workflows/WeatherWorkflow.example.hs`.
- Create: `duraflow-core/README.md`, `duraflow-core/.gitignore`, `workflows/README.md`.
- Modify: `stack.yaml`, `README.md`, `.github/workflows/ci.yml`.
- Preserve: root Nix files, all unrelated working tree and index changes.

**Interfaces:**

- Consumes: the empty public module `Duraflow`, the existing test entrypoint `main :: IO ()`, and the existing weather API sketch.
- Produces: the same library and test component in the nested package. No executable component and no new Haskell API.
- Root `stack build`, `stack test`, and `stack ghci duraflow:lib` retain their workspace roles.

- [x] **Step 1: Verify the structural expectation fails before the move.**

Run the following assertion before editing. It must fail because the new core package does not exist yet.

```sh
python3 - <<'PY'
from pathlib import Path
assert Path('duraflow-core/duraflow.cabal').is_file()
PY
```

Record the original library, test, and sketch hashes for exact move verification. Capture the existing staged entries and the root `.gitignore` content hash. Never use `git add .`, `git commit -a`, broad cleanup, or resets.

- [x] **Step 2: Move sources and remove the unused executable.**

```sh
mkdir -p duraflow-core/src duraflow-core/test workflows
mv src/Duraflow.hs duraflow-core/src/Duraflow.hs
mv test/Main.hs duraflow-core/test/Main.hs
mv duraflow.cabal duraflow-core/duraflow.cabal
mv WeatherWorkflow.example.hs workflows/WeatherWorkflow.example.hs
rm app/Main.hs
rmdir src test app
```

The executable being removed was inspected and contains only `main = pure ()`. Leave other directories and untracked files alone. If a source directory contains unrelated files, keep that directory instead of forcing its removal.

Use this Cabal content, keeping the existing package and test names:

```cabal
cabal-version:      3.0
name:               duraflow
version:            0.1.0.0
synopsis:           Durable local workflows
category:           System
description:        Haskell library scaffold for local durable workflows.
license:            NONE
build-type:         Simple
extra-source-files: README.md

common defaults
  default-language: GHC2021
  ghc-options:      -Wall -Wcompat
  build-depends:    base >=4.18 && <5

library
  import:           defaults
  hs-source-dirs:   src
  exposed-modules:  Duraflow

test-suite duraflow-test
  import:           defaults
  type:             exitcode-stdio-1.0
  hs-source-dirs:   test
  main-is:          Main.hs
  build-depends:    duraflow
```

Create `duraflow-core/.gitignore` with exactly these package-local artifact patterns. This avoids changing the user's dirty root ignore file.

```gitignore
/.stack-work/
/dist/
/dist-newstyle/
```

- [x] **Step 3: Keep the root workspace and CI working.**

In `stack.yaml`, change only the package list from `- .` to `- duraflow-core`. Preserve the resolver, compiler matching, and Nix settings.

In `.github/workflows/ci.yml`, retain the existing root cache paths and add the package build directory:

```yaml
          path: |
            ~/.stack
            .stack-work
            duraflow-core/.stack-work
```

Keep all action pins, cache key expressions, permissions, and root build/test commands unchanged.

- [x] **Step 4: Explain the separation without claiming runtime implementation.**

Create `duraflow-core/README.md`:

```markdown
# Duraflow core

This directory contains the `duraflow` Cabal library package. Its public
module is `Duraflow`. The library is currently empty and its test suite is
a placeholder. Task execution, checkpoint storage, locking, and resume
are not implemented.

Use the Stack and Nix workspace at the repository root to build and test.
The core must not import or discover application workflows. No executable,
scheduler, worker pool, or orchestrator is included in this package.
```

Create `workflows/README.md`:

```markdown
# Workflow examples

`WeatherWorkflow.example.hs` is an illustrative API sketch, not runnable
code. The proposed Duraflow API and its application-specific Weather
module do not exist yet. This directory is not a Cabal package and is not
included in the library build.

Workflows can live in any directory or repository. This directory is only
a convenient home for examples; the core does not scan it or maintain a
central workflow registry.

During development, project-aware `stack runghc` can use a built local
library. Standalone `stack script` ignores project-level `stack.yaml`, so
it needs its own compatible snapshot and a resolvable, pinned Duraflow
dependency. Neither command makes this unfinished sketch runnable.

Execution state is separate from workflow source location. A future
runtime must support an explicit state location; moving a script alone
must not change which execution it resumes.
```

Update the root README as one coherent workspace guide. Preserve the existing Nix shell instructions, dependency pin explanation, and license notice. State that there is now a library scaffold and a non-runnable weather sketch, not an executable. Replace the layout with the actual nested package and workflow paths. Replace the Fourmolu command with:

```sh
fourmolu --mode inplace duraflow-core/src/Duraflow.hs duraflow-core/test/Main.hs
```

Explain that future loop, ticket, or orchestrator components can become sibling packages, but none are created now. Link the two new directory READMEs. Remove instructions referring to the deleted executable or old root source paths.

- [x] **Step 5: Verify the structural split and source preservation.**

Run this structural check. It must now pass.

```sh
python3 - <<'PY'
from pathlib import Path
import subprocess
p = Path('duraflow-core')
assert (p / 'duraflow.cabal').is_file()
assert (p / 'README.md').is_file()
assert Path('workflows/WeatherWorkflow.example.hs').is_file()
assert not Path('duraflow.cabal').exists()
assert not Path('app/Main.hs').exists()
assert not Path('WeatherWorkflow.example.hs').exists()
assert 'executable duraflow' not in (p / 'duraflow.cabal').read_text()
assert '  - duraflow-core\n' in Path('stack.yaml').read_text()
for old, new in [('src/Duraflow.hs', p / 'src/Duraflow.hs'),
                 ('test/Main.hs', p / 'test/Main.hs')]:
    expected = subprocess.check_output(['git', 'show', '16ea44a:' + old])
    assert new.read_bytes() == expected, new
print('Structural checks passed')
PY
```

Compare the sketch hash to its recorded original. Check that nested artifacts are ignored using `git check-ignore duraflow-core/.stack-work/example`. Verify that the staged entries present before implementation are unchanged and that the root ignore-file hash is unchanged.

- [x] **Step 6: Build, test, and verify source packaging.**

```sh
nix develop path:. --command stack build --test --no-run-tests
nix develop path:. --command stack test
nix develop path:. --command stack sdist
nix develop path:. --command fourmolu --mode check duraflow-core/src/Duraflow.hs duraflow-core/test/Main.hs
git diff --check
```

Expect a successful library/test build and the existing test suite to pass. Inspect the generated source archive to verify that it contains `duraflow.cabal`, `README.md`, `src/Duraflow.hs`, and `test/Main.hs`, but no app executable or weather sketch. Document pre-existing Cabal metadata warnings rather than expanding this structural change into licensing or packaging policy work.

- [x] **Step 7: Commit only the intended paths and report.**

Stage only the files listed in this task, including the old tracked paths being removed. Use a conventional commit such as `refactor: separate core library from workflow examples`. Because unrelated changes are already staged, commit with an explicit path list using `git commit --only`. Do not commit the user's files, even though they are in the index.

Record the commit, exact validation commands, results, source preservation checks, and any limitations in the task report. Run independent spec and quality review before delivery.

## Execution record

Task 1 was implemented in commit `e00eba1` and passed independent spec and quality review. Structural checks, the pinned Stack build and test suite, Fourmolu, and whitespace checks passed. `stack ghci duraflow:lib` loaded the relocated module and exited successfully. The original library, test, and weather sketch contents were preserved. Original staged index entries and the root ignore file were independently checked and remain unchanged.

`stack sdist` produced the correct archive, including the package README, Cabal file, library source, and test source, and excluding application files. The command returned exit 1 because the unchanged package metadata has `license: NONE`; it also warned that no maintainer is set. This is not a successful metadata validation or a publishable package. Choosing a license or maintainer is outside this structural change.

The existing test suite is still a placeholder. No runtime or runnable weather application was implemented.

## Delivery after task review

Commit this plan separately using `docs: plan core and workflow workspace split`. After the implementation and final review, push only the feature branch using GitHub access mediated by `gh`, and create one focused PR into `main`. Include the spec, plan, structural changes, and validation evidence. Do not merge, touch `main`, or publish runtime packages. The user has explicitly authorized implementation and push.
