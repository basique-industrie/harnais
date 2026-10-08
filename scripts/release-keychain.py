#!/usr/bin/env python3
"""Create and remove a per-run signing keychain without logging credentials."""
import base64
import json
import os
from pathlib import Path
import secrets
import shlex
import subprocess
import sys


REQUIRED = (
    "APPLE_DEVELOPER_ID_APPLICATION_P12", "APPLE_DEVELOPER_ID_PASSWORD",
    "APPLE_NOTARY_KEY_ID", "APPLE_NOTARY_KEY_ISSUER", "APPLE_NOTARY_KEY_P8",
    "HARNAIS_NATIVE_OAUTH_CATALOG",
)


def run(*args):
    result = subprocess.run(args, capture_output=True, text=True)
    if result.returncode:
        # Called commands may have passwords in argv; never print CalledProcessError.
        raise RuntimeError(f"{args[0]} {args[1]} failed (exit {result.returncode}).")
    return result.stdout.strip()


def decode_key(value):
    # Both macOS and Linux base64 exports may contain line wrapping.
    return base64.b64decode("".join(value.split()), validate=True)


def prepare(root):
    missing = [name for name in REQUIRED if not os.environ.get(name)]
    if missing:
        raise RuntimeError("Missing release environment secrets: " + ", ".join(missing))
    catalog = os.environ["HARNAIS_NATIVE_OAUTH_CATALOG"]
    json.loads(catalog)
    root.mkdir(mode=0o700)
    keychain = root / "signing.keychain-db"
    original = {
        "default": shlex.split(run("security", "default-keychain", "-d", "user"))[0],
        "search": shlex.split(run("security", "list-keychains", "-d", "user")),
    }
    (root / "original.json").write_text(json.dumps(original))
    password = secrets.token_urlsafe(32)
    run("security", "create-keychain", "-p", password, str(keychain))
    run("security", "set-keychain-settings", "-lut", "21600", str(keychain))
    run("security", "unlock-keychain", "-p", password, str(keychain))
    run("security", "list-keychains", "-d", "user", "-s", str(keychain), *original["search"])
    run("security", "default-keychain", "-d", "user", "-s", str(keychain))
    p12 = root / "certificate.p12"
    p8 = root / "notary.p8"
    try:
        p12.write_bytes(decode_key(os.environ[REQUIRED[0]]))
        run("security", "import", str(p12), "-k", str(keychain),
            "-P", os.environ[REQUIRED[1]], "-T", "/usr/bin/codesign", "-f", "pkcs12")
        for certificate in sorted(Path("packaging/certs").glob("*.cer")):
            # Some PKCS#12 exports already contain the public intermediate CA.
            imported = subprocess.run(["security", "import", str(certificate), "-k", str(keychain), "-t", "cert"],
                                      capture_output=True, text=True)
            if imported.returncode and "already exists" not in imported.stderr:
                raise RuntimeError(f"Could not import public certificate {certificate.name}.")
        run("security", "set-key-partition-list", "-S", "apple-tool:,apple:,codesign:",
            "-s", "-k", password, str(keychain))
        p8.write_bytes(decode_key(os.environ["APPLE_NOTARY_KEY_P8"]))
        run("xcrun", "notarytool", "store-credentials", "harnais-release",
            "--key", str(p8), "--key-id", os.environ["APPLE_NOTARY_KEY_ID"],
            "--issuer", os.environ["APPLE_NOTARY_KEY_ISSUER"], "--keychain", str(keychain))
    finally:
        p12.unlink(missing_ok=True)
        p8.unlink(missing_ok=True)
    Path("Sources/Infrastructure/Resources/official-oauth-clients.json").write_text(catalog)
    print("Prepared temporary signing keychain and native OAuth registrations.")


def cleanup(root):
    errors = []
    original = root / "original.json"
    if original.exists():
        settings = json.loads(original.read_text())
        for args in (
            ("security", "default-keychain", "-d", "user", "-s", settings["default"]),
            ("security", "list-keychains", "-d", "user", "-s", *settings["search"]),
        ):
            try:
                run(*args)
            except RuntimeError as error:
                errors.append(str(error))
    keychain = root / "signing.keychain-db"
    if keychain.exists():
        try:
            run("security", "delete-keychain", str(keychain))
        except RuntimeError as error:
            errors.append(str(error))
    for name in ("certificate.p12", "notary.p8"):
        (root / name).unlink(missing_ok=True)
    Path("Sources/Infrastructure/Resources/official-oauth-clients.json").unlink(missing_ok=True)
    if errors:
        raise RuntimeError("Cleanup failed: " + "; ".join(errors))
    original.unlink(missing_ok=True)
    if root.exists():
        root.rmdir()
    print("Signing credentials removed.")


if __name__ == "__main__":
    os.umask(0o077)
    try:
        # Deliberately restricted to CI: never remove a developer's local catalog.
        if os.environ.get("GITHUB_ACTIONS") != "true":
            raise RuntimeError("This helper is for GitHub Actions only.")
        directory = Path(os.environ["RUNNER_TEMP"]) / "harnais-signing"
        if sys.argv[1:] == ["prepare"]:
            prepare(directory)
        elif sys.argv[1:] == ["cleanup"]:
            cleanup(directory)
        else:
            raise RuntimeError("Usage: release-keychain.py prepare|cleanup")
    except (RuntimeError, ValueError, OSError, KeyError) as error:
        # JSON/base64 errors expose only parser diagnostics, not secret values.
        print(str(error), file=sys.stderr)
        sys.exit(1)
