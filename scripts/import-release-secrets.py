#!/usr/bin/env python3
"""Install Iles's sealed secret transfer; never accepts or prints plaintext."""
import json
from pathlib import Path
import subprocess
import sys


REPOSITORY = "basique-industrie/harnais"
ENDPOINT = f"repos/{REPOSITORY}/environments/release"
NAMES = {
    "APPLE_DEVELOPER_ID_APPLICATION_P12", "APPLE_DEVELOPER_ID_PASSWORD",
    "APPLE_NOTARY_KEY_ID", "APPLE_NOTARY_KEY_ISSUER", "APPLE_NOTARY_KEY_P8",
    "HARNAIS_NATIVE_OAUTH_CATALOG",
}


def api(path, body=None):
    args = ["gh", "api", path]
    if body is not None:
        args += ["--method", "PUT", "--input", "-"]
    result = subprocess.check_output(args, input=json.dumps(body).encode() if body else None)
    return json.loads(result) if result else None


def validate(transfer, key):
    if transfer.get("repository") != REPOSITORY or transfer.get("environment") != "release":
        raise ValueError("Transfer is not addressed to Harnais's release environment.")
    if any(transfer.get(field) != key[field] for field in ("key_id", "key")):
        raise ValueError("GitHub's encryption key changed; regenerate the transfer in Iles.")
    if set(transfer.get("secrets", {})) != NAMES:
        raise ValueError("Transfer must contain exactly the six release secrets.")
    import base64
    for value in transfer["secrets"].values():
        if len(base64.b64decode(value, validate=True)) <= 48:
            raise ValueError("Invalid sealed secret.")


def main(path):
    transfer = json.loads(Path(path).read_text())
    key = api(ENDPOINT + "/secrets/public-key")
    validate(transfer, key)
    environment = api(ENDPOINT)
    reviewers = [rule for rule in environment["protection_rules"]
                 if rule["type"] == "required_reviewers" and rule.get("reviewers")]
    if not reviewers:
        raise ValueError("Configure required reviewers before importing signing credentials.")
    for name, value in sorted(transfer["secrets"].items()):
        api(ENDPOINT + "/secrets/" + name, {"key_id": key["key_id"], "encrypted_value": value})
        print(f"Installed {name} (encrypted).")


if __name__ == "__main__":
    try:
        if len(sys.argv) != 2:
            raise ValueError("Usage: import-release-secrets.py encrypted-transfer.json")
        main(sys.argv[1])
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
