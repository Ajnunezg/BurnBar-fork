# ADR 017 — Services layering and composition root

## Status

Accepted (2026-09-26). Executed by
[`docs/SERVICES_DECOMPOSITION_PROGRAM.md`](../SERVICES_DECOMPOSITION_PROGRAM.md).

## Context

`AgentLens/Services` (182k LOC, 579 files) has no god files, but the whole app is one dependency
knot. On `origin/main` 32b5d9bafa, 37 of the 47 AgentLens components are a single strongly
connected component. That knot includes the persistence layer (`DataStore`), `Models`, `App` and
`Views`. Services are wired through `OpenBurnBarRuntimeContext`, which has about 40 optional slots
filled after construction, and through 59 `static shared` singletons.

Earlier ratchets gated sizes and counts (file length, `try?`, singleton reads). None of them
gated **direction**, so every new feature could add an edge in either direction. A package split
is impossible while the graph is cyclic: the compiler would pull the whole knot into the first
module.

## Decision

1. **Layers.** AgentLens components are assigned to six ordered layers in
   `config/services-layers.json`: `foundation` → `contracts` → `persistence` → `platform` →
   `feature` → `app`. A component may reference its own layer or a lower one.
2. **Acyclic components.** Same-layer references are allowed only while the component graph
   stays acyclic.
3. **Contracts by convention.** `Services/<Feature>/Contracts/**` holds a feature's value types
   and protocols. A type moves there only when something below the feature needs it. These
   directories become the features' interface modules.
4. **The daemon transport is persistence.** The app's single-writer SQLite writes go through the
   daemon socket, so `Services/DaemonIPC` (socket client, runtime paths, error type) sits beside
   `Services/DataStore`, not under the daemon *manager* feature.
5. **No new files in the `Services/` root.** Every file belongs to a feature, to foundation, or to
   the composition root in `App/`.
6. **Composition root.** Construction moves out of `Services/` into a phased composition root in
   `App/`. Each runtime phase is a plain struct built by constructor injection. New code must not
   add optional post-construction slots, `configureShared` hooks, or `static shared` owners.
7. **Fitness function, not convention.** `scripts/debt/services_layering.py` resolves type
   references from source and enforces rules 1, 2, 5 and manifest completeness in CI. Existing
   debt is a shrink-only baseline keyed by component edge and symbol.
8. **Modularize last.** SwiftPM targets are carved bottom-up only after a layer is acyclic
   (program Wave 5). Door-tested targets exclude Firebase and AppKit/SwiftUI adapters.

## Consequences

- A PR that points a lower layer at a higher one, or closes a cycle, fails the fast door with the
  exact `src -> dst : Symbol` and the list of remedies. Features can no longer widen the knot by
  accident.
- A move inside a component never touches the baseline. A move that retires debt prints
  `Improved:` and must ratchet the baseline down.
- Presentation members (`Color`, `DesignSystem`) cannot live on models, stores or services. They
  go in `Views`/`Theme` extensions.
- `DataStoreCoordinator` still owns `DashboardUsageViewModel` as a read model. Splitting the
  facade into persistence and read-model parts is deferred, because inverting ownership would
  change observation timing on a perf-tuned path.
- Name resolution is heuristic (top-level declarations, stripped comments and strings). It can
  miss references hidden in string interpolation or through type inference. That makes it a
  lower bound on coupling, never a false alarm from nested types. The compiler becomes the
  enforcer once Wave 5 turns layers into modules.
