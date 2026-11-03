#!/usr/bin/env python3
"""Prepare a signed appcast and changelog notes locally. Nothing is uploaded."""

import argparse
import base64
import html
from pathlib import Path
import plistlib
import re
import subprocess
import zipfile


ROOT = Path(__file__).resolve().parent.parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path, help="Folder containing release zip archives")
    parser.add_argument("--download-url-prefix", required=True, help="Final URL of the release assets, ending in /")
    parser.add_argument("--generator", type=Path,
                        default=ROOT / ".build/artifacts/sparkle/Sparkle/bin/generate_appcast")
    parser.add_argument("--changelog", type=Path, default=ROOT / "CHANGELOG.md")
    arguments = parser.parse_args()
    directory = arguments.directory.resolve()
    archives = sorted(directory.glob("*.zip"))
    if not archives:
        parser.error("The release folder contains no zip archives.")
    if not arguments.generator.is_file():
        parser.error("Sparkle's generate_appcast is missing. Run swift package resolve first.")
    sections = {}
    version = None
    for line in arguments.changelog.read_text().splitlines():
        if line.startswith("## "):
            match = re.match(r"## \[?(\d+(?:\.\d+)+)\]?(?:\s|$)", line)
            version = match.group(1) if match else None
            if version:
                sections[version] = []
        elif version:
            sections[version].append(line)
    notes = []
    builds = set()
    for archive in archives:
        with zipfile.ZipFile(archive) as contents:
            candidates = [name for name in contents.namelist()
                          if name.count("/") == 2 and name.endswith(".app/Contents/Info.plist")]
            if len(candidates) != 1:
                parser.error(f"{archive.name}: expected one application at the archive root.")
            information = plistlib.loads(contents.read(candidates[0]))
        if information.get("CFBundleIdentifier") != "com.exgota.LocalDictation":
            parser.error(f"{archive.name}: unexpected application identifier.")
        version = information.get("CFBundleShortVersionString")
        build = information.get("CFBundleVersion")
        if not build or build in builds:
            parser.error(f"{archive.name}: missing or duplicate CFBundleVersion.")
        builds.add(build)
        if version not in sections or not any(line.strip() for line in sections[version]):
            parser.error(f"{archive.name}: no changelog section for {version}.")
        try:
            public_key = base64.b64decode(information.get("SUPublicEDKey", ""), validate=True)
        except (ValueError, TypeError):
            public_key = b""
        if len(public_key) != 32:
            parser.error(f"{archive.name}: configure the Sparkle public key before preparing a release.")
        # Escaped plain text keeps every changelog word without interpreting untrusted HTML.
        text = "\n".join(sections[version]).strip()
        notes.append((archive.with_suffix(".html"),
                      f"<h2>Local Dictation {html.escape(version)}</h2>\n<pre style=\"white-space: pre-wrap\">"
                      f"{html.escape(text)}</pre>\n"))
    for path, contents in notes:
        path.write_text(contents)
    subprocess.run([str(arguments.generator.resolve()), "--download-url-prefix", arguments.download_url_prefix,
                    "--embed-release-notes", "--maximum-versions", "0", "--maximum-deltas", "0",
                    "-o", str(directory / "appcast.xml"), str(directory)], check=True)
    print(f"Prepared {directory / 'appcast.xml'}. No files were published.")


if __name__ == "__main__":
    main()
