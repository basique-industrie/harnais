#!/usr/bin/env python3
"""Validate actual Harnais exports against pinned or current upstream T3 contracts."""
import argparse
import json
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def gh(endpoint):
    return json.loads(subprocess.check_output(["gh", "api", endpoint], text=True))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--latest", action="store_true", help="Check current Stable and latest Nightly instead of the CI pins.")
    parser.add_argument("--report", type=Path, default=ROOT / "dist/t3-compatibility.json")
    args = parser.parse_args()
    config = json.loads((ROOT / "scripts/t3-compatibility.json").read_text())
    repository = config["repository"]
    releases = config["releases"]
    if args.latest:
        recent = gh(f"repos/{repository}/releases?per_page=100")
        stable = gh(f"repos/{repository}/releases/latest")
        nightly = max((release for release in recent if "-nightly." in release["tag_name"] and not release["draft"]),
                      key=lambda release: release["published_at"])
        releases = []
        for channel, release in (("stable", stable), ("nightly", nightly)):
            tag = release["tag_name"]
            ref = gh(f"repos/{repository}/git/ref/tags/{tag}")["object"]
            if ref["type"] == "tag":
                ref = gh(f"repos/{repository}/git/tags/{ref['sha']}")["object"]
            if ref["type"] != "commit":
                raise ValueError("Release tag does not resolve to a commit.")
            releases.append(dict(channel=channel, tag=tag, commit=ref["sha"]))
    subprocess.run(["swift", "build", "-c", "debug", "--product", "HarnaisTests"], cwd=ROOT, check=True, stdout=subprocess.DEVNULL)
    bin_path = subprocess.check_output(["swift", "build", "-c", "debug", "--show-bin-path"], cwd=ROOT, text=True).strip()
    results = []
    args.report.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="harnais-t3-contracts-") as directory:
        root = Path(directory)
        subprocess.run([str(Path(bin_path) / "HarnaisTests"), "--write-t3-contract-fixtures", str(root)], check=True)
        for release in releases:
            commit = release["commit"]
            if not re.fullmatch(r"[a-f0-9]{40}", commit):
                raise ValueError("A full upstream commit is required.")
            results.append(dict(release, status="checking"))
            args.report.write_text(json.dumps({"mode": "latest" if args.latest else "pinned", "results": results}, indent=2) + "\n")
            print(f"Checking T3 {release['tag']} at {commit}", flush=True)
            target = root / release["channel"]
            target.mkdir()
            archive = target / "source.tar.gz"
            with archive.open("wb") as handle:
                subprocess.run(["gh", "api", f"repos/{repository}/tarball/{commit}"], stdout=handle, check=True)
            with tarfile.open(archive) as tar:
                for member in tar:
                    parts = Path(member.name).parts[1:]
                    relative = Path(*parts)
                    if (not member.isfile() or ".." in parts
                            or not (parts[:3] == ("packages", "contracts", "src") or parts == ("pnpm-workspace.yaml",))):
                        continue
                    output = target / relative
                    output.parent.mkdir(parents=True, exist_ok=True)
                    output.write_bytes(tar.extractfile(member).read())
            catalog = (target / "pnpm-workspace.yaml").read_text()
            match = re.search(r"^  effect: [\"']?([0-9]+\.[0-9]+\.[0-9]+(?:-[a-zA-Z0-9.-]+)?)", catalog, re.M)
            if not match:
                raise ValueError("Cannot resolve the upstream Effect version.")
            effect = match[1]
            (target / "package.json").write_text(json.dumps({"private": True, "type": "module", "dependencies": {"effect": effect}}))
            # No upstream build/install hooks, app credentials, or live settings are used.
            subprocess.run(["npm", "install", "--ignore-scripts", "--no-audit", "--no-fund", "--loglevel=error"], cwd=target, check=True)
            shutil.copyfile(ROOT / "scripts/check-t3-contracts.mjs", target / "check.mjs")
            subprocess.run(["node", "check.mjs", str(root / "harnais.json"), "legacy" if re.match(r"^v0\.0\.(\d+)", release["tag"]) and int(re.match(r"^v0\.0\.(\d+)", release["tag"])[1]) <= 45 else "mutation"], cwd=target, check=True)
            result = dict(release, status="passed", effect=effect, **json.loads((target / "result.json").read_text()))
            results[-1] = result
            args.report.write_text(json.dumps({"mode": "latest" if args.latest else "pinned", "results": results}, indent=2) + "\n")
    print(f"T3 compatibility passed for {len(results)} releases.")


if __name__ == "__main__":
    main()
