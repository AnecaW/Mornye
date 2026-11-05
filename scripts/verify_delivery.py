#!/usr/bin/env python3
"""Verify real mobile package contents and record their source provenance."""
import argparse
import hashlib
import json
import plistlib
import re
import subprocess
import zipfile
from pathlib import Path


def android_version_code(build_number, abis):
    # Flutter 3.47 split APKs reserve a 1000-code range for each ABI.
    # See FlutterPluginConstants.ABI_VERSION in the pinned Flutter SDK.
    offsets = {"armeabi-v7a": 1000, "arm64-v8a": 2000, "x86_64": 4000}
    return str(int(build_number) + (offsets[next(iter(abis))] if len(abis) == 1 else 0))


def verify(package, commit, aapt=None):
    with zipfile.ZipFile(package) as archive:
        names = archive.namelist()
        if archive.testzip() is not None:
            raise ValueError("Corrupt package archive")
        if package.suffix == ".apk":
            binary = archive.read("lib/arm64-v8a/libapp.so")
            required = ["lib/arm64-v8a/libflutter.so", "lib/arm64-v8a/libmornye_mobile.so"]
            if "assets/flutter_assets/kernel_blob.bin" in names:
                raise ValueError("Debug Dart kernel found in release APK")
            if not aapt:
                raise ValueError("aapt2 is required to verify the APK manifest")
            badging = subprocess.check_output([aapt, "dump", "badging", str(package)], text=True)
            manifest = subprocess.check_output([aapt, "dump", "xmltree", str(package), "--file", "AndroidManifest.xml"], text=True)
            if re.search(r"android:debuggable.*(?:0xffffffff|true)", manifest):
                raise ValueError("APK is debuggable")
            version = re.search(r"versionName='([^']+)'", badging).group(1)
            number = re.search(r"versionCode='([^']+)'", badging).group(1)
            identifier = re.search(r"package: name='([^']+)'", badging).group(1)
        elif package.suffix == ".ipa":
            roots = [name for name in names if re.fullmatch(r"Payload/[^/]+\.app/Info.plist", name)]
            if len(roots) != 1:
                raise ValueError("IPA must contain exactly one application in Payload")
            info = plistlib.loads(archive.read(roots[0]))
            root = roots[0].removesuffix("Info.plist")
            binary = archive.read(root + "Frameworks/App.framework/App")
            required = [root + info["CFBundleExecutable"], root + "Extensions/LinkNowPlaying.appex/LinkNowPlaying"]
            version, number, identifier = info["CFBundleShortVersionString"], info["CFBundleVersion"], info["CFBundleIdentifier"]
        else:
            raise ValueError("Expected an APK or IPA")
        for name in required:
            if not archive.read(name):
                raise ValueError(f"Required native component is empty: {name}")
        markers = [b"Automatic music cache", b"Music transfers", b"Upload and keep originals", commit[:8].encode()]
        for marker in markers:
            if marker not in binary:
                raise ValueError(f"Compiled implementation/provenance marker missing: {marker!r}")
    pubspec = Path("pubspec.yaml").read_text()
    expected_version, expected_number = re.search(r"^version:\s*([^+\s]+)\+(\d+)", pubspec, re.M).groups()
    expected_package_number = expected_number
    if package.suffix == ".apk":
        abis = {name.split("/")[1] for name in names if re.fullmatch(r"lib/[^/]+/libapp\.so", name)}
        expected_package_number = android_version_code(expected_number, abis)
    if (version, number) != (expected_version, expected_package_number):
        raise ValueError(f"Package version {version}+{number} differs from source")
    return {"file": package.name, "bytes": package.stat().st_size,
            "sha256": hashlib.file_digest(package.open("rb"), "sha256").hexdigest(),
            "version": version, "build_number": expected_number, "package_version_code": number, "application_id": identifier,
            "commit": commit, "release_aot_verified": True,
            "compiled_feature_markers_verified": True, "discord_sdk": False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("package", type=Path)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--aapt")
    args = parser.parse_args()
    result = verify(args.package, args.commit, args.aapt)
    args.package.with_suffix(".json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
