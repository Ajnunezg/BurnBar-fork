"""
Where the local MCP gets the cloud vault key for its hosted encrypted tools.

That one 32-byte key opens every end-to-end sealed session log, title, snippet
and Project Memory snapshot, so it is read from the OS secret store at the
moment a cloud tool needs it and never from the process environment by default:
every same-user process, and the agent harness that launched this MCP, can read
that environment, and harnesses write it to their logs (opencode review F9).

Sources, in order, mirroring `tools/openburnbar-mcp-remote/src/vaultStore.ts`:

1. macOS: the Keychain generic password service=com.openburnbar.mcp-remote,
   account=vault-key. OpenBurnBar writes it from Settings > Cloud > Remote MCP >
   Link this Mac's CLI, and the remote MCP reads the same item, so one link
   serves both.
2. Elsewhere: the same service/account pair in libsecret, looked up with
   `secret-tool` when it is on PATH. Provision it with
   `secret-tool store --label='OpenBurnBar MCP vault key' service com.openburnbar.mcp-remote account vault-key`,
   which reads the secret from its prompt, never from argv.
3. OPENBURNBAR_CLOUD_VAULT_KEY_BASE64, only while
   OPENBURNBAR_ALLOW_INSECURE_VAULT_KEY_SOURCE is exactly "true": tests and
   disposable CI.

The variable without the opt-in is refused rather than ignored, so a client
config that still exports it gets a migration hint instead of a silent miss.
Each lookup runs the store's CLI from an argv list with no shell, a closed stdin
(this process's stdin is the MCP protocol pipe), captured output and a timeout,
and any failure there reads as "not found". The key never goes on argv, into an
exception or into a log.
"""

from __future__ import annotations

import base64
import os
import shutil
import subprocess
import sys
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass, field

KEY_STORE_SERVICE = "com.openburnbar.mcp-remote"
KEY_STORE_ACCOUNT = "vault-key"
INSECURE_VAULT_KEY_ENV = "OPENBURNBAR_CLOUD_VAULT_KEY_BASE64"
ALLOW_INSECURE_VAULT_KEY_SOURCE_ENV = "OPENBURNBAR_ALLOW_INSECURE_VAULT_KEY_SOURCE"
# Long enough to answer the Keychain's "allow access" prompt, which macOS shows
# when a binary other than the app that wrote the item reads it, until the user
# picks Always Allow.
LOOKUP_TIMEOUT_SECONDS = 30
_SECURITY = "/usr/bin/security"

_MACOS_HINT = (
    "on macOS open OpenBurnBar > Settings > Cloud > Remote MCP > Link this Mac's CLI, which stores it in the "
    f"Keychain (service {KEY_STORE_SERVICE}, account {KEY_STORE_ACCOUNT})"
)
_LINUX_HINT = (
    f"on Linux run `secret-tool store --label='OpenBurnBar MCP vault key' service {KEY_STORE_SERVICE} "
    f"account {KEY_STORE_ACCOUNT}` and paste the base64 key at its prompt"
)
UNCONFIGURED_REASON = f"no cloud vault key in the OS secret store: {_MACOS_HINT}; {_LINUX_HINT}"
INSECURE_SOURCE_REFUSED_REASON = (
    f"{INSECURE_VAULT_KEY_ENV} is set, but the local MCP no longer reads the cloud vault key from its environment, "
    "where same-user processes and agent harnesses can read and log it. Remove the variable from this MCP server's "
    f"client config and your shell profile, then store the key in the OS secret store: {_MACOS_HINT}; {_LINUX_HINT}. "
    f"Tests or disposable CI only: also set {ALLOW_INSECURE_VAULT_KEY_SOURCE_ENV}=true."
)

# Runs one lookup argv and returns its stdout, or None (or raises) when it failed.
Runner = Callable[[Sequence[str]], bytes | None]


@dataclass(frozen=True)
class CloudVaultKey:
    """A usable key and the store that supplied it. `key` stays out of repr()."""

    key: bytes = field(repr=False)
    source: str


@dataclass(frozen=True)
class CloudVaultKeyUnavailable:
    """Why there is no usable key, as the local MCP's `unavailable` payload fields."""

    code: str
    reason: str
    detail: dict[str, str] = field(default_factory=dict)


def read_cloud_vault_key(
    environ: Mapping[str, str] | None = None,
    *,
    platform: str | None = None,
    run: Runner | None = None,
    which: Callable[[str], str | None] | None = None,
) -> CloudVaultKey | CloudVaultKeyUnavailable:
    """
    Resolve the cloud vault key from the sources in the module docstring.

    Every collaborator is injectable so tests never reach a real key store:
    `environ` (default os.environ), `platform` (default sys.platform), `run`
    (default: a bounded subprocess) and `which` (default shutil.which).
    """
    env = os.environ if environ is None else environ
    lookup = _secure_store_lookup(sys.platform if platform is None else platform, which or shutil.which)
    if lookup is not None:
        source, argv = lookup
        secret = _read_secret(run or _run_lookup, argv)
        if secret:
            return _validated(secret, source)
    insecure_value = env.get(INSECURE_VAULT_KEY_ENV, "").strip()
    if not insecure_value:
        return CloudVaultKeyUnavailable("CLOUD_VAULT_KEY_UNCONFIGURED", UNCONFIGURED_REASON)
    if env.get(ALLOW_INSECURE_VAULT_KEY_SOURCE_ENV) != "true":
        return CloudVaultKeyUnavailable("CLOUD_VAULT_KEY_INSECURE_SOURCE_REFUSED", INSECURE_SOURCE_REFUSED_REASON)
    return _validated(insecure_value, "env")


def _secure_store_lookup(platform: str, which: Callable[[str], str | None]) -> tuple[str, list[str]] | None:
    if platform == "darwin":
        return "macos-keychain", [
            _SECURITY,
            "find-generic-password",
            "-s",
            KEY_STORE_SERVICE,
            "-a",
            KEY_STORE_ACCOUNT,
            "-w",
        ]
    secret_tool = which("secret-tool")
    if secret_tool:
        return "libsecret", [secret_tool, "lookup", "service", KEY_STORE_SERVICE, "account", KEY_STORE_ACCOUNT]
    return None


def _read_secret(run: Runner, argv: Sequence[str]) -> bytes | None:
    """One lookup's trimmed stdout. A missing binary, a timeout or a non-zero exit is a miss."""
    try:
        output = run(argv)
    except (OSError, subprocess.SubprocessError):
        return None
    return output.strip() if output else None


def _run_lookup(argv: Sequence[str]) -> bytes | None:
    completed = subprocess.run(
        list(argv),
        stdin=subprocess.DEVNULL,
        capture_output=True,
        timeout=LOOKUP_TIMEOUT_SECONDS,
        check=False,
    )
    return completed.stdout if completed.returncode == 0 else None


def _validated(raw: bytes | str, source: str) -> CloudVaultKey | CloudVaultKeyUnavailable:
    try:
        key = base64.b64decode(raw, validate=True)
    except ValueError as exc:
        return CloudVaultKeyUnavailable(
            "CLOUD_VAULT_KEY_INVALID",
            "cloud vault key must be base64",
            {"error": str(exc), "keySource": source},
        )
    if len(key) != 32:
        return CloudVaultKeyUnavailable(
            "CLOUD_VAULT_KEY_INVALID",
            "cloud vault key must decode to 32 bytes",
            {"keySource": source},
        )
    return CloudVaultKey(key=key, source=source)
