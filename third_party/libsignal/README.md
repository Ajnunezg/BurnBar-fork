# Official Signal libsignal Pin

OpenBurnBar pins official Signal libsignal in `manifest.json`.

Current pin:

- Tag: `v0.103.0`
- Tag object: `6c573a122a5e1055408d7de00388ac9d6e7dfdf4`
- Source commit: `ba133bd3457f556fbf56db0a5ab985de0af79da6`
- License: `AGPL-3.0-only`

Use this manifest for Swift, Kotlin/Android, Rust, and Node bridge work. Do not
introduce a second Signal Protocol implementation or a different libsignal fork
without updating the legal notices, source-offer docs, and compliance gate.

Runtime status lives in `runtime-readiness.json`. The readiness verifier is
intentionally fail-closed until every platform writes new private-domain
ciphertext through official libsignal and the migration/read-only legacy gates
are complete:

```bash
bash scripts/ci/verify-libsignal-runtime-readiness.sh
```

The Node bridge now has a real protocol harness, not just a package-load check:

```bash
npm test --prefix packages/libsignal-bridge
```

That harness establishes an official libsignal session, consumes one-time
prekeys, marks Kyber prekeys used, decrypts out-of-order Whisper messages,
rejects replay, and proves safety-number changes when the remote identity key
changes. It is evidence for the Node protocol surface; it is not proof that
macOS, iOS, Android, Functions, or hosted-service writes have migrated.

The shared Node envelope contract lives in
`packages/signal-envelope-contracts`. It validates staged Signal transport and
at-rest envelope shapes for Functions and hosted services, but it is only a
schema/export-sanitization gate; it does not make official libsignal the runtime
crypto core.
