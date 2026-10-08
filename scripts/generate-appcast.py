#!/usr/bin/env python3
"""Generate the signed update feed with the source-pinned Sparkle tool."""
import importlib.util
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile


def main():
    with Path("Sources/HarnaisCore/Info.plist").open("rb") as handle:
        info = plistlib.load(handle)
    if not info.get("SUPublicEDKey"):
        print("This older source tag predates in-app updates; no appcast required.")
        return
    secret = os.environ.get("SPARKLE_ED_PRIVATE_KEY")
    if not secret:
        raise ValueError("Missing release environment secret: SPARKLE_ED_PRIVATE_KEY")
    spec = importlib.util.spec_from_file_location("publisher", Path(__file__).with_name("publish-release.py"))
    publisher = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(publisher)
    version, _, notes = publisher.metadata(sys.argv[1])
    archive, _ = publisher.artifacts(version, Path("dist"))
    tool = Path(".build/artifacts/sparkle/Sparkle/bin/generate_appcast").resolve()
    with tempfile.TemporaryDirectory(prefix="harnais-appcast-") as directory:
        root = Path(directory)
        os.link(archive, root / archive.name)
        (root / archive.with_suffix(".md").name).write_text(notes)
        command = [str(tool), "--ed-key-file", "-", "--embed-release-notes", "--maximum-deltas", "0",
                   "--download-url-prefix", f"https://github.com/{publisher.REPOSITORY}/releases/download/v{version}/",
                   "--link", f"https://github.com/{publisher.REPOSITORY}/releases/tag/v{version}"]
        if "-" in version:
            command += ["--channel", "preview"]
        result = subprocess.run(command + [str(root)], input=secret, text=True, capture_output=True,
                                env={k: v for k, v in os.environ.items() if k != "SPARKLE_ED_PRIVATE_KEY"})
        if result.returncode:
            # Never echo a secret-bearing subprocess or its output on failure.
            raise ValueError("Sparkle could not generate the signed feed. Check its signing key and the app's public key.")
        shutil.copyfile(root / "appcast.xml", "dist/appcast.xml")
    publisher.verify_appcast(Path("dist/appcast.xml"), archive)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
