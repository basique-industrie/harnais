#!/usr/bin/env python3
"""Exercise Sparkle signing and public verification with disposable keys/apps."""
import base64
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
TOOL = ROOT / ".build/artifacts/sparkle/Sparkle/bin/generate_appcast"


def main():
    with tempfile.TemporaryDirectory(prefix="harnais-appcast-tests-") as directory:
        root = Path(directory)
        key_script = root / "key.swift"
        key_script.write_text('import CryptoKit\nimport Foundation\nlet key = Curve25519.Signing.PrivateKey()\nprint(key.rawRepresentation.base64EncodedString())\nprint(key.publicKey.rawRepresentation.base64EncodedString())\n')
        private, public = subprocess.check_output(["swift", str(key_script)], text=True).splitlines()
        verifier = root / "verify"
        subprocess.run(["swiftc", str(ROOT / "scripts/verify-appcast.swift"), "-o", str(verifier)], check=True)
        with (ROOT / "Sources/HarnaisCore/Info.plist").open("rb") as handle:
            info = plistlib.load(handle)
        info["SUPublicEDKey"] = public
        info["CFBundleShortVersionString"] = "1.2.3"
        info["CFBundleVersion"] = "123"
        app = root / "Harnais.app"
        (app / "Contents/MacOS").mkdir(parents=True)
        shutil.copyfile("/usr/bin/true", app / "Contents/MacOS/HarnaisApp")
        os.chmod(app / "Contents/MacOS/HarnaisApp", 0o755)
        plist = app / "Contents/Info.plist"
        plist.write_bytes(plistlib.dumps(info))
        subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True, capture_output=True)
        archive = root / "Harnais-1.2.3-arm64.zip"
        subprocess.run(["ditto", "-c", "-k", "--keepParent", str(app), str(archive)], check=True)
        result = subprocess.run([str(TOOL), "--ed-key-file", "-", "--maximum-deltas", "0", "--download-url-prefix",
                                 "https://github.com/basique-industrie/harnais/releases/download/v1.2.3/", str(root)],
                                input=private, text=True, capture_output=True)
        if result.returncode:
            raise RuntimeError("Disposable Sparkle fixture signing failed: " + result.stdout + result.stderr)
        feed = root / "appcast.xml"
        original_feed = feed.read_bytes()
        original_archive = archive.read_bytes()

        def verify(success):
            result = subprocess.run([str(verifier), str(feed), str(archive), str(plist)], capture_output=True, text=True)
            assert (result.returncode == 0) == success, result.stdout + result.stderr

        verify(True)
        feed.write_bytes(original_feed.replace(b"1.2.3", b"9.9.9", 1))
        verify(False)
        feed.write_bytes(original_feed)
        archive.write_bytes(original_archive + b"tamper")
        verify(False)
        archive.write_bytes(original_archive)
        info["SUPublicEDKey"] = base64.b64encode(os.urandom(32)).decode()
        plist.write_bytes(plistlib.dumps(info))
        verify(False)
        info["SUPublicEDKey"] = public
        info["CFBundleVersion"] = "124"
        plist.write_bytes(plistlib.dumps(info))
        verify(False)
        info["CFBundleVersion"] = "123"
        plist.write_bytes(plistlib.dumps(info))
        feed.write_bytes(original_feed.split(b"<!-- sparkle-signatures:", 1)[0])
        verify(False)
    print("Signed update tests: 6 passed (valid, tampered feed/archive, wrong key/build, unsigned feed).")


if __name__ == "__main__":
    main()
