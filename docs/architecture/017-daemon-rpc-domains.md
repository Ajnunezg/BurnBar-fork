# ADR 017 — Daemon RPC domains and the surface ceiling

## Status

Accepted (2026-09-26)

## Context

The daemon serves its whole socket RPC surface (196 methods) from one actor,
`BurnBarDaemonServer`. The router was a single `switch` over every method, and
every handler was an extension on the server, so decoding, encoding and error
mapping for every call ran on that one actor. The surface grew by roughly 11
methods per strangler wave with no ceiling: `check-rpc-method-freeze.sh` pinned
the method table but was never wired into CI, and the TypeSpec snapshot only
asked for an `--update` to acknowledge an addition. The 2026-09-26 diligence
review named this as hidden rewrite risk #2: without a per-domain split and a
method ceiling, the daemon becomes the next monolith.

## Decision

- **Domains are a type.** `BurnBarDaemonRPCDomain` (22 cases) partitions
  `BurnBarRPCMethod`; each case owns one `Set` in
  `BurnBarDaemonSocketRPCCoverage.swift`. The raw value is the wire-level domain
  name in the BurnBarRPC IPC canon. Linux privacy became its own `privacy`
  domain, matching its own handler, instead of hiding inside `config`.
- **The router dispatches on domains, not methods.** After the unchanged
  front door (token check, T-DMN-01 capability attenuation, per-PID rate
  limit), `responseData` resolves the domain and either calls an isolated
  handler or the domain's server extension. The domain `switch` is exhaustive,
  so a new domain cannot compile without a routing decision.
- **Isolated domain handlers run off the server actor.** A handler in
  `RPC/Domains/` is a `Sendable` value conforming to
  `BurnBarDaemonRPCDomainHandler`. It holds only its own dependencies, which are
  actors or `Sendable` services, and its `nonisolated async` `handle` runs on the
  global executor. The server builds it per call from current state, so a
  dependency swapped at runtime (the chat store during `code.database.restore`)
  is never stale. `BurnBarDaemonRPCWire` gives the server and the handlers
  byte-identical envelope encoding. Six domains moved: `chat`, `membership`,
  `client`, `tooling`, `fleet`, `war_room`.
- **Synchronous database writers stay on the actor.** `switcher` and
  `database_recovery` write the SQLite file that `code.database.restore`
  replaces synchronously on the server actor. Moving them off would let a write
  land mid-swap, so they stay actor-bound until that restore path owns its own
  serialization.
- **The surface has a ceiling.** `budgets/daemon-rpc-domain-baseline.json` and
  `scripts/debt/check-rpc-domain-ceiling.sh` (fast-feedback, with a self-test)
  enforce:
  - at most 36 methods per domain; a domain that outgrows it must split,
  - at most 210 methods in total (one strangler wave of headroom),
  - a frozen, shrink-only actor-bound surface (172 methods today) with
    per-domain counts, so **new methods land in an isolated domain handler**.

  `check-rpc-method-freeze.sh` is now wired alongside it, so every addition is
  still acknowledged against the protocol baseline that ADR 005 cites.

## Consequences

- The server actor's RPC surface shrank from 196 to 172 methods, and it can
  only shrink from here. Isolated calls no longer queue behind unrelated work on
  the server actor while decoding and encoding.
- Adding a method now requires choosing a domain. The ceiling gate points a new
  method at an isolated handler; growing an actor-bound domain or raising a
  ceiling is a visible budget edit a reviewer must accept.
- Moving another domain off the actor is a mechanical step: add a handler under
  `RPC/Domains/`, return it from `isolatedRPCHandler(for:)`, delete the server
  extension, and run `check-rpc-domain-ceiling.sh --update` to ratchet the
  budget down. Candidates in order of coupling: `observability`, `usage`,
  `lifecycle`, then the large domains (`mission_control`, `config`, `inbox`).
- `mission_control` holds 34 methods against the cap of 36; its next growth
  forces a split.
