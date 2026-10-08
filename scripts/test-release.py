#!/usr/bin/env python3
"""Regression checks for release validation, recovery and secret transfer."""
import base64
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch


def load(name):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


release = load("publish-release")
transfer = load("import-release-secrets")
keychain = load("release-keychain")


class ReleaseTests(unittest.TestCase):
    def test_tag_validation_blocks_refs_and_shell_input(self):
        for tag in ("main", "v1.2", "v01.2.3", "v1.2.3+meta", "v1.2.3;echo x", "v1.2.3/other"):
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                release.validate_tag(tag)
        self.assertEqual(release.validate_tag("v1.2.3-rc.1"), "1.2.3-rc.1")

    def test_checksum_binds_exact_filename_and_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive = root / "Harnais-1.2.3-arm64.zip"
            archive.write_bytes(b"archive")
            checksum = archive.with_suffix(".zip.sha256")
            digest = hashlib.sha256(archive.read_bytes()).hexdigest()
            checksum.write_text(f"{digest}  {archive.name}\n")
            self.assertEqual(release.artifacts("1.2.3", root), (archive, checksum))
            archive.write_bytes(b"corrupt")
            with self.assertRaises(ValueError):
                release.artifacts("1.2.3", root)

    def test_api_failures_do_not_mean_release_absent(self):
        with patch.object(release, "gh", side_effect=subprocess.CalledProcessError(1, "gh")):
            with self.assertRaises(subprocess.CalledProcessError):
                release.release_for_tag("v1.2.3")

    def test_release_lookup_paginates(self):
        with patch.object(release, "gh", return_value=json.dumps([[{"tag_name": "v2.0.0"}], [{"tag_name": "v1.2.3"}]])):
            self.assertEqual(release.release_for_tag("v1.2.3")["tag_name"], "v1.2.3")

    def test_published_release_is_verified_without_mutation(self):
        existing = {"draft": False}
        with patch.object(release, "release_for_tag", return_value=existing), patch.object(release, "verify_remote_assets") as verify, patch.object(release, "gh") as gh:
            release.publish("v1.2.3", "1.2.3", "abc", "notes", [Path("a.zip")])
            verify.assert_called_once()
            gh.assert_not_called()

    def test_published_mismatch_cannot_be_replaced(self):
        with patch.object(release, "release_for_tag", return_value={"draft": False}), patch.object(release, "verify_remote_assets", side_effect=ValueError("mismatch")), patch.object(release, "gh") as gh:
            with self.assertRaises(ValueError):
                release.publish("v1.2.3", "1.2.3", "abc", "notes", [])
            gh.assert_not_called()

    def test_unrelated_draft_is_not_modified(self):
        with patch.object(release, "release_for_tag", return_value={"draft": True, "body": "someone else's draft"}), patch.object(release, "gh") as gh:
            with self.assertRaises(ValueError):
                release.publish("v1.2.3", "1.2.3", "abc", "notes", [])
            gh.assert_not_called()

    def test_partial_draft_is_repaired_before_publication(self):
        draft = {"draft": True, "body": "Source commit: `abc`", "assets": [{"name": "a.zip"}]}
        events = []
        with patch.object(release, "release_for_tag", return_value=draft), patch.object(release, "verify_remote_assets", side_effect=lambda *args: events.append("verify")), patch.object(release, "gh", side_effect=lambda *args: events.append(args)):
            release.publish("v1.2.3", "1.2.3", "abc", "notes", [Path("a.zip"), Path("a.zip.sha256")])
        self.assertEqual([item[1] for item in events[:2]], ["upload", "upload"])
        self.assertIn("--clobber", events[0])
        self.assertEqual(events[2], "verify")
        self.assertIn("--draft=false", events[3])

    def test_failed_upload_leaves_draft_unpublished(self):
        draft = {"draft": True, "body": "Source commit: `abc`", "assets": []}
        with patch.object(release, "release_for_tag", return_value=draft), patch.object(release, "gh", side_effect=subprocess.CalledProcessError(1, "gh")) as gh:
            with self.assertRaises(subprocess.CalledProcessError):
                release.publish("v1.2.3", "1.2.3", "abc", "notes", [Path("a.zip")])
        self.assertEqual(gh.call_count, 1)
        self.assertEqual(gh.call_args.args[1], "upload")

    def test_duplicate_remote_assets_are_rejected(self):
        with self.assertRaises(ValueError):
            release.verify_remote_assets("v1.2.3", [Path("a.zip")], {"assets": [{"name": "a.zip"}, {"name": "a.zip"}]})

    def test_signing_preflight_reports_all_missing_names(self):
        with patch.dict(keychain.os.environ, {}, clear=True):
            with self.assertRaisesRegex(RuntimeError, "APPLE_NOTARY_KEY_P8"):
                keychain.prepare(Path("unused"))

    def test_keychain_failures_do_not_log_arguments_or_output(self):
        result = subprocess.CompletedProcess([], 1, "secret stdout", "secret stderr")
        with patch.object(keychain.subprocess, "run", return_value=result):
            with self.assertRaises(RuntimeError) as error:
                keychain.run("security", "import", "-P", "secret password")
        self.assertNotIn("secret", str(error.exception))

    def test_transfer_rejects_wrong_recipient_or_missing_secret(self):
        key = {"key_id": "1", "key": "public-key"}
        data = dict(key, repository=transfer.REPOSITORY, environment="release",
                    secrets={name: base64.b64encode(b"x" * 50).decode() for name in transfer.NAMES})
        transfer.validate(data, key)
        with self.assertRaises(ValueError):
            transfer.validate(dict(data, environment="other"), key)
        with self.assertRaises(ValueError):
            transfer.validate(data, dict(key, key_id="2"))
        with self.assertRaises(ValueError):
            transfer.validate(dict(data, secrets={}), key)


if __name__ == "__main__":
    unittest.main()
