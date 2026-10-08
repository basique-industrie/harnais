#!/usr/bin/env python3
"""Validate and publish Harnais with gh, safely resuming an interrupted draft."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile


REPOSITORY = "basique-industrie/harnais"
VERSION = r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)(?:-(?:alpha|beta|rc)\.(?:0|[1-9][0-9]*))?"


def run(*args):
    return subprocess.check_output(args, text=True).strip()


def gh(*args):
    return run("gh", *args)


def validate_tag(tag):
    if not re.fullmatch("v" + VERSION, tag):
        raise ValueError("Expected a version tag such as v1.2.3 or v1.2.3-rc.1.")
    return tag[1:]


def metadata(tag):
    version = validate_tag(tag)
    with Path("Sources/HarnaisCore/Info.plist").open("rb") as handle:
        info = plistlib.load(handle)
    if info["CFBundleShortVersionString"] != version:
        raise ValueError("Tag does not match CFBundleShortVersionString.")
    commit = run("git", "rev-parse", "HEAD")
    if run("git", "rev-parse", f"refs/tags/{tag}^{{commit}}") != commit:
        raise ValueError("The source checkout must be at the release tag.")
    notes = []
    found = False
    for line in Path("CHANGELOG.md").read_text().splitlines():
        if line.startswith("## "):
            if found:
                break
            found = bool(re.fullmatch(r"## " + re.escape(version) + r"(?:\s.*)?", line))
        elif found:
            notes.append(line)
    if not "\n".join(notes).strip():
        raise ValueError(f"CHANGELOG.md has no notes for {version}.")
    return version, commit, "\n".join(notes).strip()


def release_for_tag(tag):
    # Like gh's own draft lookup, resolve the pending tag through GraphQL and
    # fetch the exact REST release by ID. The REST tag endpoint finds published
    # releases only; listing drafts is not a reliable read-after-write lookup.
    # An API failure must propagate, never be treated as 'release absent'.
    owner, name = REPOSITORY.split("/")
    query = """query($owner: String!, $name: String!, $tag: String!) {
        repository(owner: $owner, name: $name) {
            release(tagName: $tag) { databaseId }
        }
    }"""
    data = json.loads(gh("api", "graphql", "--raw-field", f"query={query}",
                         "--raw-field", f"owner={owner}", "--raw-field", f"name={name}",
                         "--raw-field", f"tag={tag}"))
    release = data["data"]["repository"]["release"]
    if release is None:
        return None
    return json.loads(gh("api", f"repos/{REPOSITORY}/releases/{release['databaseId']}"))


def artifacts(version, directory):
    archive = directory / f"Harnais-{version}-arm64.zip"
    checksum = archive.with_suffix(".zip.sha256")
    expected = hashlib.sha256(archive.read_bytes()).hexdigest()
    if checksum.read_text().strip() != f"{expected}  {archive.name}":
        raise ValueError("Archive checksum is missing, malformed or does not match.")
    return archive, checksum


def verify_app(version, archive):
    with tempfile.TemporaryDirectory(prefix="harnais-verify-") as directory:
        subprocess.run(["ditto", "-x", "-k", str(archive), directory], check=True)
        app = Path(directory) / "Harnais.app"
        with (app / "Contents/Info.plist").open("rb") as handle:
            info = plistlib.load(handle)
        with Path("Sources/HarnaisCore/Info.plist").open("rb") as handle:
            source_info = plistlib.load(handle)
        if (info["CFBundleShortVersionString"] != version
                or info["CFBundleVersion"] != source_info["CFBundleVersion"]
                or info["CFBundleIdentifier"] != "com.jean.harnais"):
            raise ValueError("Archive app identity or version differs from the tagged source.")
        for command in (
            ["codesign", "--verify", "--deep", "--strict", str(app)],
            ["xcrun", "stapler", "validate", str(app)],
            ["spctl", "--assess", "--type", "execute", str(app)],
        ):
            subprocess.run(command, check=True)


def verify_remote_assets(tag, files, release):
    names = [asset["name"] for asset in release["assets"]]
    if any(names.count(path.name) != 1 for path in files):
        raise ValueError("Existing release does not have exactly one of each expected asset.")
    with tempfile.TemporaryDirectory(prefix="harnais-assets-") as directory:
        gh("release", "download", tag, "--repo", REPOSITORY, "--dir", directory,
           *[item for path in files for item in ("--pattern", path.name)])
        for path in files:
            if hashlib.sha256(path.read_bytes()).digest() != hashlib.sha256((Path(directory) / path.name).read_bytes()).digest():
                raise ValueError(f"Published asset {path.name} differs; refusing to replace it.")


def publish(tag, version, commit, notes, files):
    release = release_for_tag(tag)
    if release and not release["draft"]:
        verify_remote_assets(tag, files, release)
        print(f"Release {tag} already contains these verified assets; nothing changed.")
        return
    if release is None:
        body = ("Signed and notarized macOS app for Apple silicon. Requires macOS 26 or later.\n\n"
                + notes + f"\n\nSource commit: `{commit}`\n")
        # Keep the existing-tag guard: the release API can otherwise create a
        # missing tag. Use its response directly; a newly created draft may not
        # yet appear in the repository's release listing.
        gh("api", f"repos/{REPOSITORY}/git/ref/tags/{tag}")
        release = json.loads(gh(
            "api", "--method", "POST", f"repos/{REPOSITORY}/releases",
            "--raw-field", f"tag_name={tag}",
            "--raw-field", f"target_commitish={commit}",
            "--raw-field", f"name=Harnais {version}",
            "--raw-field", f"body={body}",
            "--field", "draft=true",
            "--field", "prerelease=" + str("-" in version).lower()))
    # Retry only a draft created by this publisher for this exact source commit.
    if f"Source commit: `{commit}`" not in (release.get("body") or ""):
        raise ValueError("Existing draft belongs to another publication; inspect it before retrying.")
    endpoint = f"repos/{REPOSITORY}/releases/{release['id']}"
    # A rebuild has different signing timestamps. Replace both assets only in
    # our own unpublished draft, so a crash between uploads is recoverable.
    for path in files:
        gh("release", "upload", tag, str(path), "--repo", REPOSITORY, "--clobber")
    # Refresh this exact release rather than rediscovering it through a list.
    release = json.loads(gh("api", endpoint))
    verify_remote_assets(tag, files, release)
    gh("api", "--method", "PATCH", endpoint, "--field", "draft=false",
       "--field", "prerelease=" + str("-" in version).lower())
    print(f"Published https://github.com/{REPOSITORY}/releases/tag/{tag}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("validate-tag", "preflight", "verify", "publish"))
    parser.add_argument("tag")
    parser.add_argument("--artifacts", type=Path, default=Path("dist"))
    args = parser.parse_args()
    validate_tag(args.tag)
    if args.command == "validate-tag":
        return
    version, commit, notes = metadata(args.tag)
    if args.command == "preflight":
        release = release_for_tag(args.tag)
        published = release is not None and not release["draft"]
        if published and os.environ.get("RELEASE_DRY_RUN") != "true":
            # Verify the existing publication, then skip rebuilding. Signed
            # archives are not byte-reproducible because of Apple timestamps.
            with tempfile.TemporaryDirectory(prefix="harnais-published-") as directory:
                gh("release", "download", args.tag, "--repo", REPOSITORY, "--dir", directory,
                   "--pattern", f"Harnais-{version}-arm64.zip",
                   "--pattern", f"Harnais-{version}-arm64.zip.sha256")
                files = artifacts(version, Path(directory))
                verify_app(version, files[0])
            print(f"Published {args.tag} verified; no assets will be changed.")
        if os.environ.get("GITHUB_OUTPUT"):
            with open(os.environ["GITHUB_OUTPUT"], "a") as handle:
                handle.write(f"published={str(published).lower()}\n")
        print(f"Validated {args.tag} at {commit}. Existing release: {release is not None}.")
        return
    files = artifacts(version, args.artifacts)
    verify_app(version, files[0])
    if args.command == "publish":
        publish(args.tag, version, commit, notes, files)
    else:
        print(f"Verified signed and notarized {args.tag}.")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
