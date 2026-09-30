import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import {
  candidateCloseRefusal,
  collectCandidateFingerprint,
  collectNativeArtifactDigests,
  NATIVE_ARTIFACT_PATHS
} from './lib/candidate-fingerprint.mjs';

function git(cwd, args) {
  const result = spawnSync('git', args, { cwd, encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr);
  return result.stdout.trim();
}

function initRepo() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'obb-fingerprint-'));
  git(root, ['init']);
  git(root, ['config', 'user.email', 'm0@example.com']);
  git(root, ['config', 'user.name', 'M0']);
  fs.writeFileSync(path.join(root, 'README'), 'ok\n');
  git(root, ['add', 'README']);
  git(root, ['commit', '-m', 'init']);
  return root;
}

test('collectCandidateFingerprint records SHA and clean status', () => {
  const root = initRepo();
  const fingerprint = collectCandidateFingerprint(root);
  assert.equal(fingerprint.commitSha, git(root, ['rev-parse', 'HEAD']));
  assert.equal(fingerprint.dirty, false);
  assert.deepEqual(fingerprint.dirtyEntries, []);
  assert.equal(candidateCloseRefusal(fingerprint), null);
});

test('dirty tree is recorded and cannot close a candidate', () => {
  const root = initRepo();
  fs.writeFileSync(path.join(root, 'dirty.txt'), 'nope\n');
  const fingerprint = collectCandidateFingerprint(root);
  assert.equal(fingerprint.dirty, true);
  assert.ok(fingerprint.dirtyEntries.some((line) => line.includes('dirty.txt')));
  assert.match(candidateCloseRefusal(fingerprint), /dirty tree cannot be a closable candidate/);
});

test('native artifact digests cover missing paths, single files, and directory trees', (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'obb-native-digest-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const write = (relative, body) => {
    fs.mkdirSync(path.dirname(path.join(root, relative)), { recursive: true });
    fs.writeFileSync(path.join(root, relative), body);
  };
  write('Vendor/opus-android.aar', 'aar-bytes');
  write('Vendor/OpenBurnBarSignalFfi.xcframework/Info.plist', 'plist');
  write('Vendor/OpenBurnBarSignalFfi.xcframework/ios-arm64/libffi.a', 'archive');

  const digests = new Map(collectNativeArtifactDigests(root).map((item) => [item.path, item]));
  assert.deepEqual([...digests.keys()], NATIVE_ARTIFACT_PATHS);
  assert.deepEqual(digests.get('Vendor/opus-android.aar'), {
    path: 'Vendor/opus-android.aar',
    present: true,
    sha256: crypto.createHash('sha256').update('aar-bytes').digest('hex')
  });
  const tree = crypto.createHash('sha256');
  for (const [relative, body] of [['Info.plist', 'plist'], [path.join('ios-arm64', 'libffi.a'), 'archive']]) {
    tree.update(relative);
    tree.update(body);
  }
  assert.deepEqual(digests.get('Vendor/OpenBurnBarSignalFfi.xcframework'), {
    path: 'Vendor/OpenBurnBarSignalFfi.xcframework',
    present: true,
    sha256: tree.digest('hex')
  });
  for (const missing of [
    'Vendor/OpenBurnBarSignalFfiIOS.xcframework',
    'Vendor/openburnbar-iroh.aar',
    'android/openburnbar-domain-core'
  ]) {
    assert.deepEqual(digests.get(missing), { path: missing, present: false, sha256: null });
  }
});

test('candidateCloseRefusal rejects missing SHA and missing fingerprint', () => {
  assert.match(candidateCloseRefusal(null), /missing/);
  assert.match(
    candidateCloseRefusal({ commitSha: 'not-a-sha', dirty: false, dirtyEntries: [] }),
    /canonical/
  );
});
