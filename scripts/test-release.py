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

    def test_draft_lookup_uses_pending_tag_then_exact_release_id(self):
        draft = {"id": 123, "tag_name": "v1.2.3", "draft": True}
        data = {"data": {"repository": {"release": {"databaseId": 123}}}}
        with patch.object(release, "gh", side_effect=[json.dumps(data), json.dumps(draft)]) as gh:
            self.assertEqual(release.release_for_tag("v1.2.3"), draft)
        self.assertEqual(gh.call_args_list[0].args[:2], ("api", "graphql"))
        self.assertIn("tag=v1.2.3", gh.call_args_list[0].args)
        self.assertEqual(gh.call_args_list[1].args, ("api", f"repos/{release.REPOSITORY}/releases/123"))

    def test_null_release_means_absent(self):
        data = {"data": {"repository": {"release": None}}}
        with patch.object(release, "gh", return_value=json.dumps(data)) as gh:
            self.assertIsNone(release.release_for_tag("v1.2.3"))
        gh.assert_called_once()

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
        draft = {"id": 123, "draft": True, "body": "Source commit: `abc`", "assets": [{"name": "a.zip"}]}
        events = []

        def gh(*args):
            events.append(args)
            return json.dumps(draft)

        with patch.object(release, "release_for_tag", return_value=draft) as lookup, patch.object(release, "verify_remote_assets", side_effect=lambda *args: events.append("verify")), patch.object(release, "gh", side_effect=gh):
            release.publish("v1.2.3", "1.2.3", "abc", "notes", [Path("a.zip"), Path("a.zip.sha256")])
        lookup.assert_called_once()
        self.assertEqual([item[1] for item in events[:2]], ["upload", "upload"])
        self.assertIn("--clobber", events[0])
        self.assertEqual(events[2], ("api", f"repos/{release.REPOSITORY}/releases/123"))
        self.assertEqual(events[3], "verify")
        self.assertIn("PATCH", events[4])
        self.assertIn("draft=false", events[4])

    def test_new_draft_uses_creation_response_even_when_listing_is_empty(self):
        draft = {"id": 123, "draft": True, "body": "Source commit: `abc`", "assets": []}
        uploaded = dict(draft, assets=[{"name": "a.zip"}])
        events = []

        def gh(*args):
            events.append(args)
            if "POST" in args:
                return json.dumps(draft)
            if args == ("api", f"repos/{release.REPOSITORY}/releases/123"):
                return json.dumps(uploaded)
            return ""

        with patch.object(release, "release_for_tag", return_value=None) as lookup, patch.object(release, "gh", side_effect=gh), patch.object(release, "verify_remote_assets") as verify:
            release.publish("v1.2.3", "1.2.3", "abc", "notes", [Path("a.zip")])
        lookup.assert_called_once_with("v1.2.3")
        self.assertEqual(events[0], ("api", f"repos/{release.REPOSITORY}/git/ref/tags/v1.2.3"))
        self.assertIn("POST", events[1])
        self.assertIn("draft=true", events[1])
        self.assertIn("tag_name=v1.2.3", events[1])
        self.assertIn("target_commitish=abc", events[1])
        verify.assert_called_once_with("v1.2.3", [Path("a.zip")], uploaded)
        self.assertIn("PATCH", events[-1])
        self.assertIn("draft=false", events[-1])

    def test_missing_remote_tag_prevents_draft_creation(self):
        with patch.object(release, "release_for_tag", return_value=None), patch.object(release, "gh", side_effect=subprocess.CalledProcessError(1, "gh")) as gh:
            with self.assertRaises(subprocess.CalledProcessError):
                release.publish("v1.2.3", "1.2.3", "abc", "notes", [])
        gh.assert_called_once_with("api", f"repos/{release.REPOSITORY}/git/ref/tags/v1.2.3")

    def test_failed_asset_verification_leaves_draft_unpublished(self):
        draft = {"id": 123, "draft": True, "body": "Source commit: `abc`", "assets": []}
        with patch.object(release, "release_for_tag", return_value=draft), patch.object(release, "gh", return_value=json.dumps(draft)) as gh, patch.object(release, "verify_remote_assets", side_effect=ValueError("mismatch")):
            with self.assertRaises(ValueError):
                release.publish("v1.2.3", "1.2.3", "abc", "notes", [Path("a.zip")])
        self.assertFalse(any("PATCH" in call.args for call in gh.call_args_list))

    def test_failed_upload_leaves_draft_unpublished(self):
        draft = {"id": 123, "draft": True, "body": "Source commit: `abc`", "assets": []}
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

    def test_signing_keys_accept_wrapped_base64(self):
        self.assertEqual(keychain.decode_key("Y2Vy\ndGlm\naWNhdGU=\n"), b"certificate")
        with self.assertRaises(ValueError):
            keychain.decode_key("not a certificate!")

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
