#!/usr/bin/env python3
"""Validate the built personal fork, then package an unsigned IPA without installing it."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import stat
import subprocess
import zipfile


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--source-root", type=Path, required=True)
    parser.add_argument("--stamp", required=True)
    args = parser.parse_args()
    app = args.app.resolve(strict=True)
    with (app / "Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    if info.get("CFBundleIdentifier") != "com.ppanphper.roamcontrol":
        raise SystemExit("Wrong bundle identifier: would risk replacing a reference installation")
    minimum = tuple(map(int, info.get("MinimumOSVersion", "999").split(".")))
    if minimum > (26, 5, 2):
        raise SystemExit("MinimumOSVersion excludes iOS 26.5.2")
    if not info.get("RoamControlBuildTimestamp") or "$" in info["RoamControlBuildTimestamp"]:
        raise SystemExit("Missing immutable build timestamp")
    if any(info.get(key, "").strip() for key in ("RoamControlTelemetryAppID", "RoamControlTelemetryNamespace")):
        raise SystemExit("Personal build must have empty statistics configuration")
    if any("Tunnel" in p.name for p in app.rglob("*.appex")):
        raise SystemExit("Unexpected tunnel extension")
    executable = app / info["CFBundleExecutable"]
    if not executable.is_file() or not os.access(executable, os.X_OK):
        raise SystemExit("Missing executable or executable permission")
    privacy = plistlib.loads((app / "PrivacyInfo.xcprivacy").read_bytes())
    if privacy.get("NSPrivacyTracking") is not False:
        raise SystemExit("Tracking declaration changed")
    schemes = [scheme for item in info.get("CFBundleURLTypes", []) for scheme in item.get("CFBundleURLSchemes", [])]
    if "roamcontrol-pandy" not in schemes:
        raise SystemExit("Missing isolated callback scheme")
    locales = {"en", "he", "ar", "zh-Hans", "zh-Hant", "ja", "vi", "fr", "de", "es"}
    if not locales.issubset({path.stem for path in app.glob("*.lproj")}):
        raise SystemExit("Missing packaged language resources")
    subprocess.run(["python3", str(args.source_root / "scripts/validate-localizations.py"),
                    "--resources", str(app)], check=True)
    build_platform = subprocess.check_output(["xcrun", "vtool", "-show-build", str(executable)], text=True)
    if "platform IOS\n" not in build_platform or "minos 26.0" not in build_platform:
        raise SystemExit("Unexpected executable platform or minimum OS: " + build_platform)
    args.output_dir.mkdir(parents=True, exist_ok=True)
    stem = f"Roam-Control-{info['CFBundleShortVersionString']}-Build{info['CFBundleVersion']}-{args.stamp}"
    ipa = args.output_dir / (stem + ".ipa")
    if ipa.exists():
        raise SystemExit("Refusing to overwrite an existing package")
    with zipfile.ZipFile(ipa, "x", zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
        for path in sorted(app.rglob("*")):
            name = "Payload/" + app.name + "/" + str(path.relative_to(app))
            if path.is_symlink():
                entry = zipfile.ZipInfo(name)
                entry.create_system = 3
                entry.external_attr = (stat.S_IFLNK | 0o777) << 16
                archive.writestr(entry, os.readlink(path))
            else:
                archive.write(path, name)
    with zipfile.ZipFile(ipa) as archive:
        if archive.testzip() is not None:
            raise SystemExit("ZIP integrity check failed")
        entry = archive.getinfo("Payload/" + app.name + "/" + executable.name)
        if not (entry.external_attr >> 16) & stat.S_IXUSR:
            raise SystemExit("IPA executable permission lost")
    def git(*command):
        return subprocess.check_output(["git", "-C", str(args.source_root), *command], text=True).strip()
    paths = git("ls-files", "--cached", "--others", "--exclude-standard").splitlines()
    source_files = {}
    for relative in sorted(set(paths)):
        if relative.startswith(("RoamControl/", "RoamControl.xcodeproj/", "Native/", "Frameworks/", "Configuration/")):
            path = args.source_root / relative
            if path.is_file():
                source_files[relative] = hashlib.sha256(path.read_bytes()).hexdigest()
    source_digest = hashlib.sha256(json.dumps(source_files, sort_keys=True).encode()).hexdigest()
    manifest = {
        "file": ipa.name,
        "sha256": hashlib.sha256(ipa.read_bytes()).hexdigest(),
        "main_executable_sha256": hashlib.sha256(executable.read_bytes()).hexdigest(),
        "bytes": ipa.stat().st_size,
        "version": info["CFBundleShortVersionString"], "build": info["CFBundleVersion"],
        "bundle_identifier": info["CFBundleIdentifier"], "minimum_os": info["MinimumOSVersion"],
        "build_timestamp_utc": info["RoamControlBuildTimestamp"],
        "display_name": info.get("CFBundleDisplayName"), "callback_schemes": schemes,
        "source_head": git("rev-parse", "HEAD"), "source_branch": git("branch", "--show-current"),
        "source_has_uncommitted_changes": bool(git("status", "--porcelain")),
        "build_source_tree_sha256": source_digest,
        "build_source_files_sha256": source_files,
        "languages": sorted(locales),
        "executable_build_platform": build_platform.strip(),
        "packaging": "unsigned Release archive; ZIP CRC and executable permission verified",
        "device_verification": "pending user: iOS 26.5.2, LiveContainer + LocalDevVPN",
        "telemetry_configuration_empty": True,
        "no_tunnel_extension": True,
    }
    manifest_path = args.output_dir / (stem + ".json")
    manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({"ipa": str(ipa), "manifest": str(manifest_path), "sha256": manifest["sha256"]}, ensure_ascii=False))


if __name__ == "__main__":
    main()
