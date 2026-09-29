// Account-erasure barrier across the team lane (codex diligence 2026-09).
//
// The personal barrier (`isSignedIn()`) denies every request from a UID with an
// `account_erasure_tombstones/{uid}` marker, but team authorization used
// `request.auth != null` plus the live roster row. A still-valid token for a
// user whose erasure is pending could keep reading and writing team data for as
// long as their roster row stayed active. Every assertion below is proven
// reachable first: the same principal succeeds before its tombstone lands, so
// each later denial can only come from the barrier.
import { assertFails, assertSucceeds, initializeTestEnvironment } from "@firebase/rules-unit-testing";
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { Timestamp, collection, deleteDoc, doc, getDoc, getDocs, setDoc, updateDoc } from "firebase/firestore";

const PROJECT_ID = process.env.FIRESTORE_TEST_PROJECT_ID || "burnbar-test";
const RULES_PATH = resolve(dirname(fileURLToPath(import.meta.url)), "..", "firestore.rules");
const FIRESTORE_HOST = process.env.FIRESTORE_TEST_HOST || "127.0.0.1";
const FIRESTORE_PORT = Number.parseInt(process.env.FIRESTORE_TEST_PORT || "8080", 10);

const teamId = "team_erasure_barrier01";
const adminUid = "erasing-admin-uid";
const memberUid = "erasing-member-uid";
const peerUid = "healthy-peer-uid";
const NOW = Timestamp.fromDate(new Date("2026-09-28T00:00:00.000Z"));
// Base64 of a 32-byte digest: 43 characters plus the pad, as escrow devices store it.
const FINGERPRINT = `${"b".repeat(43)}=`;
const WRAPPED = Buffer.from("wrapped-fixture", "utf8").toString("base64");

const hex = (char) => char.repeat(64);

function teamFact(uid, docID, overrides = {}) {
  return {
    uid,
    teamId,
    docID,
    schemaVersion: 2,
    sourceKind: "agent",
    kind: "architecture",
    reviewStatus: "approved",
    sealedMemory: {
      schemaVersion: 2,
      algorithm: "AES-256-GCM",
      keyVersion: 1,
      plaintextHMAC: hex("a"),
      integrityHashVersion: 1,
      sealedBoxBase64: "c2VhbGVkLWJsb2I=",
      createdAt: "2026-09-28T00:00:00.000Z",
      aad: `OpenBurnBar-CloudVault-aad-v2|team:${teamId}|team_memory_facts|${docID}|sealedMemory|2|sealedMemory`,
    },
    sourceRefHmacs: [hex("a")],
    citationCount: 1,
    validFrom: NOW,
    updatedAt: NOW,
    replicatedAt: NOW,
    teamKeyVersion: 1,
    ...overrides,
  };
}

function envelope(uid, deviceId) {
  return {
    teamId,
    uid,
    deviceId,
    escrowKeyVersion: 1,
    keySlot: "v1",
    algorithm: "ECIES-P256-AESGCM",
    wrappedKeyBase64: WRAPPED,
    recipientPublicKeyFingerprint: FINGERPRINT,
    wrappedBy: uid,
    createdAt: NOW,
  };
}

const envelopeId = (uid, deviceId) => `${uid}_${deviceId}_1_v1`;

function forgetReceipt(uid, receiptID) {
  return {
    uid,
    teamId,
    receiptID,
    schemaVersion: 1,
    memoryIdHmac: hex("c"),
    sourceRefHmacs: [hex("d")],
    reason: "user_delete",
    createdAt: NOW,
    replicatedAt: NOW,
  };
}

const testEnv = await initializeTestEnvironment({
  projectId: PROJECT_ID,
  firestore: {
    rules: readFileSync(RULES_PATH, "utf8"),
    host: FIRESTORE_HOST,
    port: FIRESTORE_PORT,
  },
});

async function seed(path, data) {
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await setDoc(doc(context.firestore(), path), data);
  });
}

try {
  await testEnv.clearFirestore();

  await seed(`team_rosters/${teamId}`, {
    teamId,
    name: "Erasure Barrier",
    activeKeyVersion: 1,
    retainedKeyVersions: [1],
    burnedKeyVersions: [],
    slugKeyId: null,
    keyRotationRequired: false,
    createdBy: adminUid,
    schemaVersion: 1,
  });
  for (const [uid, role] of [[adminUid, "admin"], [memberUid, "member"], [peerUid, "member"]]) {
    await seed(`team_rosters/${teamId}/members/${uid}`, {
      uid,
      teamId,
      role,
      status: "active",
      escrowDeviceFingerprints: [],
      activeTeamKeyVersion: 1,
      invitedBy: adminUid,
      schemaVersion: 1,
    });
    await seed(`users/${uid}/entitlements/burnbar_pro_max`, {
      id: "burnbar_pro_max",
      active: true,
      productID: "com.openburnbar.proMax.v2.monthly",
      expiresAt: "2099-01-01T00:00:00.000Z",
      expireAt: Timestamp.fromDate(new Date("2099-01-01T00:00:00.000Z")),
      schemaVersion: 2,
    });
  }
  await seed(`team_rosters/${teamId}/audit_log/event-1`, { action: "member.joined", at: NOW });
  await seed(`team_memory_facts/${teamId}/facts/${hex("1")}`, teamFact(adminUid, hex("1")));
  await seed(`team_memory_facts/${teamId}/facts/${hex("2")}`, teamFact(memberUid, hex("2")));
  await seed(`team_memory_facts/${teamId}/facts/${hex("3")}`, teamFact(memberUid, hex("3")));
  await seed(`team_memory_facts/${teamId}/facts/${hex("4")}`, teamFact(peerUid, hex("4")));
  await seed(`team_key_envelopes/${teamId}/envelopes/${envelopeId(adminUid, "mac-a")}`, envelope(adminUid, "mac-a"));
  await seed(`team_memory_facts/${teamId}/forget_receipts/${hex("e")}`, forgetReceipt(memberUid, hex("e")));

  const admin = testEnv.authenticatedContext(adminUid).firestore();
  const member = testEnv.authenticatedContext(memberUid).firestore();
  const peer = testEnv.authenticatedContext(peerUid).firestore();
  const factsPath = `team_memory_facts/${teamId}/facts`;
  const receiptsPath = `team_memory_facts/${teamId}/forget_receipts`;
  const envelopesPath = `team_key_envelopes/${teamId}/envelopes`;

  // Every operation a pending-erasure principal must lose, keyed by name so a
  // failure names the path that leaked. `stage` distinguishes the pre-barrier
  // proof from the post-barrier denial, since creates need fresh document ids.
  const operations = {
    "admin reads the roster": () => getDoc(doc(admin, `team_rosters/${teamId}`)),
    "admin reads a teammate's roster row": () => getDoc(doc(admin, `team_rosters/${teamId}/members/${peerUid}`)),
    "admin reads the team audit log": () => getDoc(doc(admin, `team_rosters/${teamId}/audit_log/event-1`)),
    "admin reads a team fact": () => getDoc(doc(admin, `${factsPath}/${hex("4")}`)),
    "admin lists team facts": () => getDocs(collection(admin, factsPath)),
    "admin re-seals its own fact": () => updateDoc(doc(admin, `${factsPath}/${hex("1")}`), { updatedAt: NOW, replicatedAt: NOW }),
    "admin re-seals a teammate's fact": () => updateDoc(doc(admin, `${factsPath}/${hex("4")}`), { updatedAt: NOW, replicatedAt: NOW }),
    "admin reads its own key envelope": () => getDoc(doc(admin, `${envelopesPath}/${envelopeId(adminUid, "mac-a")}`)),
    "admin reads forget receipts": () => getDocs(collection(admin, receiptsPath)),
    "member reads its own roster row": () => getDoc(doc(member, `team_rosters/${teamId}/members/${memberUid}`)),
    "member reads a team fact": () => getDoc(doc(member, `${factsPath}/${hex("1")}`)),
    "member updates its own forget receipt": () =>
      updateDoc(doc(member, `${receiptsPath}/${hex("e")}`), { replicatedAt: NOW }),
  };
  const creates = {
    "admin creates a team fact": (stage) =>
      setDoc(doc(admin, `${factsPath}/${hex(stage === "before" ? "5" : "6")}`), teamFact(adminUid, hex(stage === "before" ? "5" : "6"))),
    "admin self-wraps a key envelope": (stage) => {
      const device = stage === "before" ? "mac-b" : "mac-c";
      return setDoc(doc(admin, `${envelopesPath}/${envelopeId(adminUid, device)}`), envelope(adminUid, device));
    },
    "member self-wraps a key envelope": (stage) => {
      const device = stage === "before" ? "phone-a" : "phone-b";
      return setDoc(doc(member, `${envelopesPath}/${envelopeId(memberUid, device)}`), envelope(memberUid, device));
    },
    "member files a forget receipt": (stage) => {
      const id = hex(stage === "before" ? "7" : "8");
      return setDoc(doc(member, `${receiptsPath}/${id}`), forgetReceipt(memberUid, id));
    },
    "member deletes its own fact": (stage) => deleteDoc(doc(member, `${factsPath}/${hex(stage === "before" ? "2" : "3")}`)),
  };

  // Stage 1 — the barrier is absent: every operation is reachable.
  for (const [name, run] of Object.entries(operations)) {
    await assertSucceeds(run()).catch((error) => {
      throw new Error(`precondition: ${name} must succeed before erasure (${error.message})`);
    });
  }
  for (const [name, run] of Object.entries(creates)) {
    await assertSucceeds(run("before")).catch((error) => {
      throw new Error(`precondition: ${name} must succeed before erasure (${error.message})`);
    });
  }

  // Stage 2 — erasure is pending for admin and member; their roster rows stay active.
  for (const uid of [adminUid, memberUid]) {
    await seed(`account_erasure_tombstones/${uid}`, { schemaVersion: 2, pending: true });
  }

  let denied = 0;
  for (const [name, run] of Object.entries(operations)) {
    await assertFails(run()).catch(() => {
      throw new Error(`pending-erasure token kept team access: ${name}`);
    });
    denied += 1;
  }
  for (const [name, run] of Object.entries(creates)) {
    await assertFails(run("after")).catch(() => {
      throw new Error(`pending-erasure token kept team access: ${name}`);
    });
    denied += 1;
  }

  // Stage 3 — no collateral damage: a teammate without a tombstone keeps access.
  await assertSucceeds(getDoc(doc(peer, `team_rosters/${teamId}`)));
  await assertSucceeds(getDoc(doc(peer, `team_rosters/${teamId}/members/${peerUid}`)));
  await assertSucceeds(getDocs(collection(peer, factsPath)));
  await assertSucceeds(getDoc(doc(peer, `${factsPath}/${hex("4")}`)));

  console.log(`team erasure barrier tests passed (${denied} pending-erasure denials, each proven reachable first)`);
} finally {
  await testEnv.cleanup();
}
