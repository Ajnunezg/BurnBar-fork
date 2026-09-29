"""The cloud vault key comes from the OS secret store; plain env is a test-only opt-in (opencode review F9).

Every lookup here goes through a fake runner or a fake executable in tmp_path;
`conftest.py` makes the default runner fail loudly, so no test can read the
machine's real Keychain item. Keys are synthetic and built at runtime.
"""

from __future__ import annotations

import base64
import functools
import json
import subprocess
import sys
from collections.abc import Sequence
from pathlib import Path

import pytest

_HERE = Path(__file__).resolve().parent
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))

import cloud_vault_key_store as store  # noqa: E402
from test_memory_engine import _load_server  # noqa: E402

# Bound at import, before conftest swaps the module attribute for a refusing stub.
REAL_RUN_LOOKUP = store._run_lookup

KEY = bytes(range(32))
KEY_B64 = base64.b64encode(KEY).decode("ascii")
OTHER_KEY_B64 = base64.b64encode(bytes(range(32, 64))).decode("ascii")
INSECURE_ENV = store.INSECURE_VAULT_KEY_ENV
ALLOW_ENV = store.ALLOW_INSECURE_VAULT_KEY_SOURCE_ENV
KEYCHAIN_ARGV = [
    "/usr/bin/security",
    "find-generic-password",
    "-s",
    "com.openburnbar.mcp-remote",
    "-a",
    "vault-key",
    "-w",
]


class _FakeStore:
    """Stands in for `security` / `secret-tool`: records each argv and answers or raises."""

    def __init__(self, answer: bytes | None = None, error: BaseException | None = None) -> None:
        self.answer = answer
        self.error = error
        self.calls: list[list[str]] = []

    def __call__(self, argv: Sequence[str]) -> bytes | None:
        self.calls.append(list(argv))
        if self.error is not None:
            raise self.error
        return self.answer


def _read(
    environ: dict[str, str] | None = None,
    *,
    platform: str,
    run: _FakeStore | None = None,
    secret_tool: str | None = None,
) -> store.CloudVaultKey | store.CloudVaultKeyUnavailable:
    return store.read_cloud_vault_key(
        environ or {},
        platform=platform,
        run=run if run is not None else _FakeStore(),
        which=lambda name: secret_tool if name == "secret-tool" else None,
    )


def _unavailable(result: object, code: str) -> store.CloudVaultKeyUnavailable:
    assert isinstance(result, store.CloudVaultKeyUnavailable), result
    assert result.code == code
    return result


def test_a_keychain_hit_returns_the_32_byte_key():
    keychain = _FakeStore(answer=KEY_B64.encode() + b"\n")

    result = _read(platform="darwin", run=keychain)

    assert isinstance(result, store.CloudVaultKey)
    assert result.key == KEY
    assert result.source == "macos-keychain"
    assert keychain.calls == [KEYCHAIN_ARGV]
    assert KEY_B64 not in repr(result)


@pytest.mark.parametrize("platform", ["darwin", "linux"])
def test_an_env_key_without_the_opt_in_is_refused_and_not_used(platform):
    result = _read({INSECURE_ENV: KEY_B64}, platform=platform, run=_FakeStore(answer=None))

    refused = _unavailable(result, "CLOUD_VAULT_KEY_INSECURE_SOURCE_REFUSED")
    assert KEY_B64 not in refused.reason
    assert refused.detail == {}
    assert "Remove the variable from this MCP server's client config" in refused.reason
    assert "Link this Mac's CLI" in refused.reason
    assert "secret-tool store --label='OpenBurnBar MCP vault key'" in refused.reason
    assert f"{ALLOW_ENV}=true" in refused.reason


def test_an_env_key_is_used_with_the_exact_true_opt_in():
    result = _read({INSECURE_ENV: KEY_B64, ALLOW_ENV: "true"}, platform="linux")

    assert isinstance(result, store.CloudVaultKey)
    assert result.key == KEY
    assert result.source == "env"


@pytest.mark.parametrize("opt_in", ["1", "yes", "on", "TRUE", "True", " true", "true "])
def test_the_opt_in_must_be_exactly_true(opt_in):
    result = _read({INSECURE_ENV: KEY_B64, ALLOW_ENV: opt_in}, platform="linux")

    _unavailable(result, "CLOUD_VAULT_KEY_INSECURE_SOURCE_REFUSED")


@pytest.mark.parametrize(
    "environ",
    [{INSECURE_ENV: OTHER_KEY_B64, ALLOW_ENV: "true"}, {INSECURE_ENV: OTHER_KEY_B64}],
    ids=["opted-in", "leftover"],
)
def test_a_keychain_key_wins_over_any_env_key(environ):
    result = _read(environ, platform="darwin", run=_FakeStore(answer=KEY_B64.encode()))

    assert isinstance(result, store.CloudVaultKey)
    assert (result.key, result.source) == (KEY, "macos-keychain")


@pytest.mark.parametrize(
    ("stored", "reason"),
    [
        (b"not base64 at all!", "cloud vault key must be base64"),
        (base64.b64encode(bytes(16)), "cloud vault key must decode to 32 bytes"),
    ],
    ids=["not-base64", "wrong-length"],
)
def test_an_invalid_keychain_value_is_invalid_and_never_falls_back_to_env(stored, reason):
    result = _read(
        {INSECURE_ENV: KEY_B64, ALLOW_ENV: "true"},
        platform="darwin",
        run=_FakeStore(answer=stored),
    )

    invalid = _unavailable(result, "CLOUD_VAULT_KEY_INVALID")
    assert invalid.reason == reason
    assert invalid.detail["keySource"] == "macos-keychain"
    assert stored.decode("ascii") not in json.dumps(invalid.detail)


def test_an_invalid_opted_in_env_value_is_invalid_without_echoing_it():
    result = _read({INSECURE_ENV: "%%not-a-key%%", ALLOW_ENV: "true"}, platform="linux")

    invalid = _unavailable(result, "CLOUD_VAULT_KEY_INVALID")
    assert invalid.detail["keySource"] == "env"
    assert "not-a-key" not in json.dumps(invalid.detail)


@pytest.mark.parametrize(
    ("answer", "error"),
    [
        (None, FileNotFoundError(2, "No such file or directory")),
        (None, PermissionError(13, "Permission denied")),
        (None, subprocess.TimeoutExpired(cmd=KEYCHAIN_ARGV, timeout=store.LOOKUP_TIMEOUT_SECONDS)),
        (None, None),
        (b"", None),
        (b" \n", None),
    ],
    ids=["missing-binary", "not-executable", "timeout", "non-zero-exit", "empty", "blank"],
)
def test_a_failed_or_empty_lookup_reads_as_not_found(answer, error):
    keychain = _FakeStore(answer=answer, error=error)

    result = _read(platform="darwin", run=keychain)

    _unavailable(result, "CLOUD_VAULT_KEY_UNCONFIGURED")
    assert keychain.calls == [KEYCHAIN_ARGV]


def test_linux_reads_the_same_item_from_libsecret():
    libsecret = _FakeStore(answer=KEY_B64.encode())

    result = _read(platform="linux", run=libsecret, secret_tool="/usr/bin/secret-tool")

    assert isinstance(result, store.CloudVaultKey)
    assert (result.key, result.source) == (KEY, "libsecret")
    assert libsecret.calls == [
        ["/usr/bin/secret-tool", "lookup", "service", "com.openburnbar.mcp-remote", "account", "vault-key"]
    ]


def test_off_macos_without_secret_tool_or_opt_in_it_is_unconfigured_with_store_instructions():
    runner = _FakeStore(answer=KEY_B64.encode())

    result = _read(platform="linux", run=runner)

    unconfigured = _unavailable(result, "CLOUD_VAULT_KEY_UNCONFIGURED")
    assert runner.calls == []
    assert "Link this Mac's CLI" in unconfigured.reason
    assert "secret-tool store --label='OpenBurnBar MCP vault key'" in unconfigured.reason
    assert INSECURE_ENV not in unconfigured.reason


def test_no_lookup_puts_the_key_on_argv():
    stores = [_FakeStore(answer=KEY_B64.encode()), _FakeStore(), _FakeStore(), _FakeStore(answer=KEY_B64.encode())]

    _read(platform="darwin", run=stores[0])
    _read({INSECURE_ENV: KEY_B64, ALLOW_ENV: "true"}, platform="darwin", run=stores[1])
    _read({INSECURE_ENV: KEY_B64}, platform="darwin", run=stores[2])
    _read(platform="linux", run=stores[3], secret_tool="/usr/bin/secret-tool")

    argvs = [argv for fake in stores for argv in fake.calls]
    assert len(argvs) == 4
    assert all(KEY_B64 not in arg for argv in argvs for arg in argv)


def test_the_default_runner_passes_argv_without_a_shell_with_stdin_closed_and_a_timeout(monkeypatch):
    seen: dict[str, object] = {}

    def fake_run(args, **kwargs):
        seen["args"] = args
        seen.update(kwargs)
        return subprocess.CompletedProcess(args, 0, stdout=KEY_B64.encode() + b"\n", stderr=b"")

    monkeypatch.setattr(subprocess, "run", fake_run)

    result = store.read_cloud_vault_key({}, platform="darwin", run=REAL_RUN_LOOKUP)

    assert isinstance(result, store.CloudVaultKey)
    assert result.key == KEY
    assert seen["args"] == KEYCHAIN_ARGV
    assert seen["stdin"] is subprocess.DEVNULL
    assert seen["capture_output"] is True
    assert seen["timeout"] == store.LOOKUP_TIMEOUT_SECONDS
    assert not seen.get("shell", False)


def _fake_cli(tmp_path: Path, script: str) -> str:
    path = tmp_path / "secret-tool"
    path.write_text("#!/bin/sh\n" + script + "\n")
    path.chmod(0o755)
    return str(path)


def test_the_default_runner_reads_a_real_lookup_process(tmp_path):
    secret_tool = _fake_cli(
        tmp_path,
        '[ "$*" = "lookup service com.openburnbar.mcp-remote account vault-key" ] || exit 3\n'
        f"printf '%s' '{KEY_B64}'",
    )

    result = store.read_cloud_vault_key({}, platform="linux", run=REAL_RUN_LOOKUP, which=lambda _name: secret_tool)

    assert isinstance(result, store.CloudVaultKey)
    assert (result.key, result.source) == (KEY, "libsecret")


@pytest.mark.parametrize(
    "script",
    [f"printf '%s' '{KEY_B64}'\nexit 1", "exec sleep 5", None],
    ids=["non-zero-exit-with-output", "timeout", "missing-binary"],
)
def test_the_default_runner_reads_process_failures_as_not_found(tmp_path, monkeypatch, script):
    monkeypatch.setattr(store, "LOOKUP_TIMEOUT_SECONDS", 0.5)
    secret_tool = _fake_cli(tmp_path, script) if script is not None else str(tmp_path / "absent")

    result = store.read_cloud_vault_key({}, platform="linux", run=REAL_RUN_LOOKUP, which=lambda _name: secret_tool)

    _unavailable(result, "CLOUD_VAULT_KEY_UNCONFIGURED")


@pytest.fixture
def server(monkeypatch):
    module = _load_server()
    monkeypatch.setenv("OPENBURNBAR_FIREBASE_ID_TOKEN", "a.b.c")
    return module


def _use_key_store(monkeypatch, server, *, platform: str, run: _FakeStore) -> None:
    monkeypatch.setattr(
        server,
        "read_cloud_vault_key",
        functools.partial(store.read_cloud_vault_key, platform=platform, run=run, which=lambda _name: None),
    )


def test_cloud_config_takes_the_vault_key_from_the_macos_keychain(server, monkeypatch):
    _use_key_store(monkeypatch, server, platform="darwin", run=_FakeStore(answer=KEY_B64.encode() + b"\n"))

    config = server._cloud_config()

    assert config["status"] == "ok"
    assert config["vaultKey"] == KEY
    assert len(config["vaultKey"]) == 32


def test_cloud_config_refuses_an_env_vault_key_without_the_opt_in(server, monkeypatch):
    monkeypatch.setenv(INSECURE_ENV, KEY_B64)
    _use_key_store(monkeypatch, server, platform="darwin", run=_FakeStore(answer=None))

    config = server._cloud_config()

    assert config == {
        "status": "unavailable",
        "code": "CLOUD_VAULT_KEY_INSECURE_SOURCE_REFUSED",
        "reason": store.INSECURE_SOURCE_REFUSED_REASON,
    }
    assert KEY_B64 not in json.dumps(config)


def test_cloud_config_checks_auth_before_touching_the_key_store(server, monkeypatch):
    monkeypatch.delenv("OPENBURNBAR_FIREBASE_ID_TOKEN")
    keychain = _FakeStore(answer=KEY_B64.encode())
    _use_key_store(monkeypatch, server, platform="darwin", run=keychain)

    config = server._cloud_config()

    assert config["code"] == "CLOUD_AUTH_UNCONFIGURED"
    assert keychain.calls == []


def test_cloud_search_answers_with_the_migration_hint_instead_of_calling_firebase(server, monkeypatch):
    monkeypatch.setenv("OPENBURNBAR_LOCAL_MCP_ENABLE_CLOUD_DECRYPT", "true")
    monkeypatch.setenv("OPENBURNBAR_LOCAL_MCP_DISABLE_AUDIT", "true")
    monkeypatch.setenv(INSECURE_ENV, KEY_B64)
    _use_key_store(monkeypatch, server, platform="darwin", run=_FakeStore(answer=None))

    def _no_firebase(*_args, **_kwargs):
        raise AssertionError("a refused vault key must not reach Firebase")

    monkeypatch.setattr(server, "_call_firebase_callable", _no_firebase)

    raw = server.burnbar_cloud_semantic_search_conversations("hosted semantic search")

    assert json.loads(raw)["code"] == "CLOUD_VAULT_KEY_INSECURE_SOURCE_REFUSED"
    assert KEY_B64 not in raw
