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
