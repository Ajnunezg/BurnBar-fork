import Foundation

/// A JSON object crossing an untyped boundary (Firestore documents, callable
/// payloads, config files, CLI streams). Config files and CLI streams carry
/// third-party keys that MUST round-trip untouched, so these stay untyped by
/// design — the alias names that intent once instead of scattering the
/// untyped-boundary spelling (tracked by the string-any ratchet) per call site.
/// Prefer a Codable model for shapes we own; reach for this only at
/// established schemaless seams.
public typealias UntypedJSONObject = [String: Any]
