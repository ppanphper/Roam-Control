#!/usr/bin/env python3
"""Validate every shipped language and its printf arguments; optionally generate from JSON."""
import argparse
from collections import Counter
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parent.parent
LANGUAGES = ("en", "he", "ar", "zh-Hans", "zh-Hant", "ja", "vi", "fr", "de", "es")
PERMISSIONS = {
    "NSLocalNetworkUsageDescription": "Roam Control uses the local network to securely pair with and control this iPhone through LocalDevVPN.",
    "NSLocationWhenInUseUsageDescription": "Roam Control uses your location to show and recenter on your real position after a location session stops.",
}
FORMAT = re.compile(r"%(?:\d+\$)?[-+#0 ']*(?:\d+|\*)?(?:\.(?:\d+|\*))?(?:hh|ll|[hlLzjtq])?[@diuoxXfFeEgGaAcCsSp]")


def signature(text):
    return Counter(re.sub(r"^%\d+\$", "%", token) for token in FORMAT.findall(text.replace("%%", "")))


def write_strings(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    lines = ["/* Public feature parity: localized app and permission text. */"]
    for key, value in sorted(data.items()):
        lines.append(f"{json.dumps(key, ensure_ascii=False)} = {json.dumps(value, ensure_ascii=False)};")
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def read_strings(path):
    return json.loads(subprocess.check_output(["plutil", "-convert", "json", "-o", "-", str(path)]))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json-source", type=Path, help="Generate all resources from this complete locale JSON directory first")
    parser.add_argument("--stringsdata-dir", type=Path, help="Check compiler-extracted source keys as well")
    parser.add_argument("--resources", type=Path, default=ROOT / "RoamControl/Resources")
    args = parser.parse_args()
    dictionaries = {}
    for code in LANGUAGES:
        if args.json_source:
            dictionaries[code] = json.loads((args.json_source / f"{code}.json").read_text())
        else:
            dictionaries[code] = read_strings(args.resources / f"{code}.lproj/Localizable.strings")
    english = dictionaries["en"]
    assert english and all(english[key] == key for key in english), "English must contain stable source keys"
    for code, values in dictionaries.items():
        assert set(values) == set(english), f"{code}: missing {set(english)-set(values)}, extra {set(values)-set(english)}"
        for key, value in values.items():
            assert isinstance(value, str) and value.strip(), f"{code}: empty value for {key}"
            assert signature(key) == signature(value), f"{code}: format mismatch: {key!r} -> {value!r}"
        expected_info = {key: values[source] for key, source in PERMISSIONS.items()}
        expected_info["CFBundleDisplayName"] = "Roam Control Dev"
        directory = args.resources / f"{code}.lproj"
        if args.json_source:
            write_strings(directory / "Localizable.strings", values)
            write_strings(directory / "InfoPlist.strings", expected_info)
        assert read_strings(directory / "Localizable.strings") == values, f"{code}: malformed resource"
        assert read_strings(directory / "InfoPlist.strings") == expected_info, f"{code}: incorrect permission text"
    if args.stringsdata_dir:
        extracted = {item["key"] for path in args.stringsdata_dir.glob("*.stringsdata")
                     for entries in json.loads(path.read_text()).get("tables", {}).values() for item in entries}
        assert extracted, "No compiler-extracted strings found"
        missing = extracted - set(english) - {""}
        assert not missing, f"Untranslated compiler keys: {sorted(missing)}"
        print(f"PASS: {len(extracted)} compiler-extracted source keys covered")
    print(f"PASS: {len(LANGUAGES)} languages × {len(english)} keys; printf arguments, permissions and resource syntax")


if __name__ == "__main__":
    main()
