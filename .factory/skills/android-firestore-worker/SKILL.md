---
name: android-firestore-worker
description: Align Android Firestore models, parsers, and stores with the TypeSpec schema canon in tools/schema-sync, then prove the alignment with the drift gate and the Android JVM suite.
---

# Android Firestore Worker

Use this skill when a TypeSpec domain under `tools/schema-sync/typespec/domains/`
changes, when `./tools/schema-sync/check-drift.sh` reports Kotlin drift, or when
an Android screen reads or writes a Firestore document whose shape is in doubt.

The canon is TypeSpec. `tools/schema-sync/manifest.json` registers every domain
(`canonicalRoot`), its Firestore collections, its emitted bindings, and its
hand-maintained mirrors. Never treat a hand-maintained TypeScript type as the
schema: `packages/functions-shared/src/types/legacy/` is migration debt that the
canon overrides.

## Phase 0 — read the contract

1. `tools/schema-sync/manifest.json`: find the domain, its `firestoreCollections`,
   its `emit.kotlin` file, and its `kotlinHandMirror` entries (with any
   `knownDrift` tokens).
2. The domain's `.tsp` file under `tools/schema-sync/typespec/domains/`.
3. The emitted Kotlin under
   `android/app/src/main/java/com/openburnbar/data/models/generated/`.
4. The hand mirror, usually
   `android/app/src/main/java/com/openburnbar/data/models/TokenUsage.kt`, plus the
   Firestore readers and stores that consume it (for rollups,
   `android/app/src/main/java/com/openburnbar/data/firebase/FirestoreRollupMerger.kt`).

## Phase 1 — regenerate, then diff every field

```bash
npm --prefix tools/schema-sync run emit        # rewrites generated TS/Swift/Kotlin
node tools/schema-sync/check-hand-mirror.mjs   # field-name diff vs the canon (Kotlin mirrors carry no optionality check)
```

Generated files are never edited by hand. If the generated Kotlin is wrong, fix
the `.tsp` or the emitter under `tools/schema-sync/emit/`, not the output.

## Phase 2 — update models, parsers, and stores

- Every data class keeps `@IgnoreExtraProperties`.
- Use `@PropertyName` where the Firestore key differs from Kotlin camelCase.
- Computed properties live in the class body, not the primary constructor.
- Convert `com.google.firebase.Timestamp` with
  `it.seconds * 1000 + it.nanoseconds / 1_000_000`.
- Rollups are five documents (`today`, `7d`, `30d`, `90d`, `all_time`);
  `mergeWindowDocs()` merges them into one `UsageRollups`.
- A `knownDrift` token in the manifest may only be removed (the drift is fixed),
  never added. The gate fails on new drift and on a stale token.

## Phase 3 — prove it

```bash
./tools/schema-sync/check-drift.sh
cd android && ./gradlew :app:testDebugUnitTest --no-daemon
cd android && ./gradlew assembleDebug
```

Report the executed test count from the Gradle run. A green drift gate with zero
executed Android tests is not proof.
