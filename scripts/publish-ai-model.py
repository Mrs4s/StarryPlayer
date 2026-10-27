#!/usr/bin/env python3
"""Verify the pinned model kit; --publish uploads it to its separate GitHub release."""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import subprocess
import tempfile
from urllib.parse import unquote, urlparse
import zipfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    parser.add_argument("--publish", action="store_true", help="Publish the verified files with an authenticated GitHub CLI")
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    descriptor = root / "App/StarryPlayer/Resources/LyricsAIModel.json"
    release = json.loads(descriptor.read_text())
    url = urlparse(release["archiveURL"])
    parts = [unquote(part) for part in url.path.strip("/").split("/")]
    if url.scheme != "https" or url.netloc != "github.com" or len(parts) != 6 or parts[2:4] != ["releases", "download"]:
        parser.error("The model descriptor must point to a versioned GitHub release asset")
    repository, tag, asset = "/".join(parts[:2]), parts[4], parts[5]
    if not tag.startswith("lyrics-ai-") or args.archive.name != asset:
        parser.error("Use a lyrics-ai-* tag and the exact asset filename from LyricsAIModel.json")
    if args.archive.stat().st_size != release["archiveBytes"]:
        parser.error("Archive size differs from the pinned descriptor")
    hasher = hashlib.sha256()
    with args.archive.open("rb") as source:
        while block := source.read(1024 * 1024):
            hasher.update(block)
    digest = hasher.hexdigest()
    if digest != release["sha256"]:
        parser.error("Archive SHA-256 differs from the pinned descriptor; do not replace an existing model version")
    with zipfile.ZipFile(args.archive) as archive:
        prefix = release["folderName"] + "/"
        for entry in archive.infolist():
            path = PurePosixPath(entry.filename)
            if not entry.filename.startswith(prefix) or path.is_absolute() or ".." in path.parts or "\\" in entry.filename:
                parser.error("Archive contains an unexpected path")
            if (entry.external_attr >> 16) & 0o170000 == 0o120000:
                parser.error("Model archives must not contain symbolic links")
        runtime = json.loads(archive.read(prefix + "metadata/runtime.json"))
        required = ["metadata/vocab.json", "metadata/mel-filters.f32", "metadata/hann-400.f32", runtime["model"] + "/Manifest.json"]
        for name in required:
            if prefix + name not in archive.namelist():
                parser.error("Missing model asset: " + name)
        if archive.testzip() is not None:
            parser.error("Archive CRC verification failed")
    print(f"Verified {asset}: {release['archiveBytes']:,} bytes\nSHA-256: {digest}\nURL: {release['archiveURL']}")
    if not args.publish:
        print("No remote changes. Add --publish to upload this model release.")
        return

    subprocess.run(["gh", "auth", "status"], check=True)
    lookup = subprocess.run(["gh", "api", f"repos/{repository}/releases/tags/{tag}"], capture_output=True, text=True)
    existing = json.loads(lookup.stdout) if lookup.returncode == 0 else None
    if existing is None and "404" not in lookup.stderr:
        raise SystemExit(lookup.stderr or "Could not look up the model release")
    if existing is not None and (not existing["prerelease"] or existing["draft"]):
        raise SystemExit("The model release must be a published prerelease, separate from app releases")
    with tempfile.TemporaryDirectory(prefix="starry-model-release-") as temporary:
        temporary = Path(temporary)
        checksum = temporary / (asset + ".sha256")
        checksum.write_text(f"{digest}  {asset}\n")
        notes = temporary / "release-notes.txt"
        notes.write_text(
            f"{release['name']} — external Core ML model for AI lyrics timing.\n\n"
            "Requires macOS 15+. Download from the lyrics editor's AI 打轴 panel, or extract the ZIP and select its folder.\n"
            "Japanese and English lyrics; CPU, GPU and Neural Engine. The kit includes metadata and dictionary notices.\n\n"
            "This is a model asset release. It is marked as a prerelease so it does not become the app update feed's latest release.\n"
            f"Model ID: {release['id']}\nSHA-256: {digest}\n"
        )
        assets = [args.archive.resolve(), checksum, descriptor]
        if existing is None:
            subprocess.run(["gh", "release", "create", tag, *map(str, assets), "--repo", repository,
                            "--prerelease", "--latest=false", "--title", release["name"], "--notes-file", str(notes)], check=True)
        else:
            uploaded = {entry["name"]: entry for entry in existing["assets"]}
            for file in assets:
                if file.name in uploaded:
                    expected = digest if file.name == asset else hashlib.sha256(file.read_bytes()).hexdigest()
                    if uploaded[file.name].get("digest") != "sha256:" + expected:
                        raise SystemExit(f"Refusing to replace existing asset {file.name}; publish a new model version instead")
                else:
                    subprocess.run(["gh", "release", "upload", tag, str(file), "--repo", repository], check=True)
        print(f"Published: https://github.com/{repository}/releases/tag/{tag}")


if __name__ == "__main__":
    main()
