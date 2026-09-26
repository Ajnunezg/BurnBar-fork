import Foundation
import OpenBurnBarKernel

// MARK: - Team memory identity (memory program D16 / P22)

/// Shared identity math for the team-memory lane, consumed by both
/// `TeamMemoryPullService` and `TeamMemorySyncService` and by the persistence
/// plane (`RemoteSyncWatermarkStore`, `ControlPlaneStore+MemoryTimeline`,
/// `ControlPlaneStore+MemorySyncInbox`). Pure statics only — no service state —
/// so this file sits at the contracts layer below both features and the store.
enum TeamMemoryIdentity {
    /// The `remote_sync_watermarks` row key for one team on one account.
    ///
    /// NO NEW TABLE and NO NEW ENUM CASE: `collectionKind` is a closed Swift
    /// enum, but `accountUid` is a free-form text column, so the team cursor
    /// rides there under a namespaced key while `collectionKind` stays
    /// `memory_facts`. It reuses that case's `firstSyncFloor` (the epoch), which
    /// is exactly right here for exactly the same reason: a team fact is state,
    /// not an event, and a member joining today wants the team's whole history.
    ///
    /// The uid is part of the key even though the team id alone would identify
    /// the collection. Two members signing into the same Mac are the ordinary
    /// case on a shared machine, and a cursor keyed on the team alone would let
    /// the first member's progress silently skip documents for the second.
    static func watermarkAccountKey(teamID: String, localUserID: String) -> String {
        "team:\(teamID):\(localUserID)"
    }

    /// What marks an `agent_memory_inbox` row as TEAM-origin, in SQL as well as
    /// in Swift.
    ///
    /// A personal row's doc id is `pensieveSlugHmac("memory-fact:<engine id>")`
    /// — 64 hex characters — so it can never begin with this, and a query that
    /// excludes the prefix excludes exactly the team rows and nothing else.
    ///
    /// THE REASON THIS HAS TO BE EXCLUDABLE. A team row is parked under the
    /// `engineMemoryID` its payload seals, which on a hostile client is a
    /// teammate's engine id (PR3 Cursor ruling, T2). Any query that joins
    /// `agent_memory_bodies` to `agent_memory_inbox` on `engine_memory_id`
    /// ALONE therefore lets a team document be read as the arrival record of the
    /// member's own private memory. Those queries filter on this prefix; the
    /// isolation invariant is not only the engine's to keep.
    static let inboxDocIDPrefix = "team:"
    /// The LOCAL engine memory id one team document lands under — DERIVED, the
    /// way `memory_engine/_namespaces.py::_team_local_memory_id` derives it, and
    /// never the `memoryID` the payload seals.
    ///
    /// WHY THE APP NEEDS ITS OWN COPY. The prefix above says why a parked team
    /// row must be excluded from any `engine_memory_id` join: that column holds
    /// the SEALED id, which is attacker-chosen on a modified client and is a key
    /// to nothing local. But the app still has one honest question to ask of a
    /// parked team document — "is this the arrival record of THIS local memory",
    /// which is what the Team Fact badge is (memory program D16 / P22) — and
    /// after PR3's ruling the only key that answers it is the engine's own
    /// derivation: SHA-256 over `(teamID, convergence identity)`, whose every
    /// input is a field of the payload itself.
    ///
    /// That makes the badge unforgeable for the same reason the engine's row
    /// identity is. Landing on a CHOSEN row would need a SHA-256 preimage, and
    /// the personal id space is unreachable by construction because a personal
    /// row's engine id is random rather than derived. A member who seals a
    /// colleague's engine id gains exactly nothing here: the value is not read.
    ///
    /// Byte-for-byte parity with Python is a cross-language contract that no
    /// build failure would catch — a drift would silently stop badging every
    /// team fact — so it is pinned as a vector on BOTH sides:
    /// `ControlPlaneStoreMemoryTimelineTests` and `test_memory_blind_sync.py`.
    ///
    /// IT CANONICALISES ITS INPUTS, BECAUSE THE ENGINE DOES (PR 4 review N2).
    /// `_screen_remote_row` derives from `project_id.strip()`,
    /// `engineScope.strip().lower()` and `str(team_id).strip()` — never from the
    /// raw payload strings — so a derivation reading them raw agrees only for
    /// already-canonical payloads and silently disagrees for the rest. The cost
    /// of disagreeing is an ABSENT BADGE, which reads exactly like "personal",
    /// which is precisely the failure the cross-language vectors exist to
    /// prevent; the vectors pin the hash, not the normalisation, so they could
    /// never have caught it.
    ///
    /// AND THE BODY HASH IS THE CALLER'S TO COMPUTE, canonically. The engine
    /// recomputes it from the GATED body and never trusts the payload's copy
    /// (`_sync.py:590-593`), so the parameter is named for what it must be and
    /// `TeamMemoryIdentity.canonicalBodyHash` is the one way to produce it.
    /// That also shrinks the attacker-controlled part of the preimage to
    /// `(teamID, projectID, engineScope)`: the body hash now comes from a body
    /// this device already holds.
    static func teamLocalEngineMemoryID(
        teamID: String,
        projectID: String,
        engineScope: String,
        canonicalBodyHash: String
    ) -> String {
        // `_convergence_key(project_id, scope, body_hash)` — §5's convergence
        // identity. Delegated to the ONE Swift copy of that contract rather than
        // re-inlined: `TeamMemoryIdentity.convergenceKey` is the same lane's
        // already cross-language-pinned implementation, and a second copy in the
        // same lane would be a drift surface that this file's own doc comment
        // argues against (PR 4 review N3).
        let identity = convergenceKey(
            teamProjectId: engineCanonicalToken(projectID),
            engineScope: engineCanonicalToken(engineScope).lowercased(),
            bodyHash: canonicalBodyHash
        )
        let outer = CloudVaultCrypto.sha256Hex("team|\(engineCanonicalToken(teamID))|\(identity)")
        return "mem_" + String(outer.prefix(32))
    }

    /// Python's `str.strip()` on a token the engine is about to shape-check.
    ///
    /// `.whitespacesAndNewlines` is the closest Foundation set; the residual
    /// difference cannot matter here because every token this trims is then held
    /// to a regex (`REMOTE_PROJECT_ID_RE`, `REMOTE_TEAM_ID_RE`, `MEMORY_SCOPES`)
    /// that admits no whitespace at all — a value the two definitions would
    /// disagree about is one the engine refuses outright, so it names no local
    /// row to badge.
    private static func engineCanonicalToken(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The shape a `teamProjectId` may take, byte-for-byte the engine's
    /// `REMOTE_WRITER_DEVICE_RE` (`^[A-Za-z0-9_.:-]{1,128}$`) and refused by
    /// `REMOTE_PROJECT_ID_RE` on the far side of the daemon boundary.
    ///
    /// WHY THIS FIELD IS BOUNDED WHEN THE PERSONAL LANE'S IS NOT. On the
    /// personal lane `projectID` is minted by the engine on the member's own
    /// Mac, so there is no author to bound. On the TEAM lane it is
    /// member-authored text read out of `.openburnbar/project.json` — a file
    /// committed to a shared repository, so anyone with commit access supplies
    /// it — and it lands in PLAINTEXT as `memories.project_id`, as part of an
    /// `engine_meta` convergence key, and as an audit-event label on every
    /// teammate's Mac, where the ungated timeline reports it to the calling
    /// model. That is a prompt-injection channel and a disclosure channel in one
    /// string, which is the same argument that bounds `teamID`, `authorUID`,
    /// `writerDevice`, `memoryID`, `supersededBy` and `previousBodyHash` — and it
    /// bites harder here, because this is the only one of them that comes from a
    /// file rather than from a machine.
    ///
    /// The token shape is deliberately permissive about CONTENT (a team names
    /// its own projects) and strict about FORM: one line, no whitespace, no
    /// punctuation an instruction could be built from, and a hard length cap.
    static let teamProjectIDPattern = "^[A-Za-z0-9_.:-]{1,128}$"
    /// The engine's own convergence identity, folded to 32 hex characters.
    ///
    /// BYTE-IDENTICAL to `memory_engine/_util.py::_convergence_key`:
    /// `sha256_hex(f"{project_id}|{scope}|{body_hash}")[:32]`. Pipes, not
    /// colons; SHA-256, not HMAC; 32 characters, not 64. Pinned from both sides
    /// by `test_the_swift_convergence_key_matches_the_python_one` and its Python
    /// twin, because a one-character drift here would silently give two members
    /// two documents for one fact and no error anywhere.
    static func convergenceKey(teamProjectId: String, engineScope: String, bodyHash: String) -> String {
        String(CloudVaultCrypto.sha256Hex("\(teamProjectId)|\(engineScope)|\(bodyHash)").prefix(32))
    }

    /// The engine's OWN body hash, recomputed from a body this device holds.
    ///
    /// BYTE-IDENTICAL to `memory_engine/_util.py::canonical_body_hash`:
    /// `sha256_hex(body.lower())`. Lowercased, and that is the whole difference
    /// that matters — the daemon-mirror hash the app stores in
    /// `agent_memory_bodies.body_hash` is `sha256_hex(body)` with NO lowering
    /// (`server.py::_memory_mirror_updated`), which `_util.py:42` names as a
    /// different hash in a different namespace that "must never be folded into
    /// this helper". Reading that column and calling it the canonical hash is
    /// therefore wrong for every body containing one capital letter.
    ///
    /// WHY THE APP RECOMPUTES RATHER THAN TRUSTS A FIELD. `_screen_remote_row`
    /// sets `body_hash = canonical_body_hash(body)` from the GATED body with the
    /// comment "the payload's `bodyHash` is the sender's advice about its own
    /// store and is deliberately never trusted as the key". Anything deriving
    /// the engine's row identity has to make the same move or it derives a
    /// different identity the moment this device's secret/PII policy redacts the
    /// body, or the sender's `bodyHash` is simply stale. Pinned across languages
    /// beside `convergenceKey` for the same reason it is.
    static func canonicalBodyHash(_ body: String) -> String {
        CloudVaultCrypto.sha256Hex(body.lowercased())
    }
}
