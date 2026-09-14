# Duraflow core

This directory contains the `duraflow` Cabal library package. Its public
module is `Duraflow`. The library is currently empty and its test suite is
a placeholder. Task execution, checkpoint storage, locking, and resume
are not implemented.

Use the Stack and Nix workspace at the repository root to build and test.
The core must not import or discover application workflows. No executable,
scheduler, worker pool, or orchestrator is included in this package.
