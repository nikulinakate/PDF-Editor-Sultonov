#!/usr/bin/env python3
"""Portable integrity checks. Compilation and PDF round-trip tests run on macOS/iOS."""
import json
import plistlib
import re
import subprocess
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
errors = []


def require(condition, message):
    if not condition:
        errors.append(message)


def strings(path):
    result = {}
    pattern = re.compile(r'("(?:[^"\\]|\\.)*")\s*=\s*("(?:[^"\\]|\\.)*");')
    for line in path.read_text().splitlines():
        match = pattern.fullmatch(line.strip())
        require(match is not None, f"Invalid string entry: {path}: {line}")
        if match:
            key, value = [json.loads(part) for part in match.groups()]
            require(key not in result, f"Duplicate localization key: {path}: {key}")
            require(bool(value), f"Empty localization value: {path}: {key}")
            result[key] = value
    return result


app_en = strings(ROOT / "PDFEditor/Resources/en.lproj/Localizable.strings")
app_ru = strings(ROOT / "PDFEditor/Resources/ru.lproj/Localizable.strings")
require(app_en.keys() == app_ru.keys(), "App EN/RU localization keys differ")
core_en = strings(ROOT / "Sources/PDFEditorCore/Resources/en.lproj/Localizable.strings")
core_ru = strings(ROOT / "Sources/PDFEditorCore/Resources/ru.lproj/Localizable.strings")
require(core_en.keys() == core_ru.keys(), "Core EN/RU localization keys differ")
all_source = "\n".join(path.read_text() for path in (ROOT / "PDFEditor").rglob("*.swift"))
for key in re.findall(r'L\("([^"\\]+)"\)', all_source):
    require(key in app_en, f"Unlocalized key: {key}")
for prefix, suffixes in {
    "tool.": ["browse", "editSource", "text", "ink", "signature", "shape", "eraser"],
    "tool.hint.": ["browse", "editSource", "text", "ink", "signature", "shape", "eraser"],
    "library.": ["all", "favorites", "trash", "empty", "noResults"],
    "demo.title.": ["0", "1", "2"], "demo.body.": ["0", "1", "2"],
    "text.": ["add", "edit"], "favorite.": ["add", "remove"]
}.items():
    for suffix in suffixes:
        require(prefix + suffix in app_en, f"Missing dynamic key: {prefix + suffix}")
for path in ROOT.rglob("*.plist"):
    with path.open("rb") as source:
        plistlib.load(source)
with (ROOT / "PDFEditor/Resources/PrivacyInfo.xcprivacy").open("rb") as source:
    plistlib.load(source)
for path in ROOT.rglob("*.json"):
    json.loads(path.read_text())
for path in ROOT.rglob("*.swift"):
    require(len(path.read_text().splitlines()) <= 700, f"Oversized Swift source: {path}")
project = ROOT / "PDFEditor.xcodeproj/project.pbxproj"
before = project.read_bytes() if project.exists() else b""
subprocess.run([sys.executable, str(ROOT / "Scripts/generate_project.py")], check=True)
require(before == project.read_bytes(), "Generated Xcode project was stale; commit the regenerated project")
for path in re.findall(r'"path" = "([^"\n]+)";\n\s*"sourceTree" = "SOURCE_ROOT"', project.read_text()):
    require((ROOT / path).exists(), f"Project references missing file: {path}")
ET.parse(ROOT / "PDFEditor.xcodeproj/xcshareddata/xcschemes/PDFEditor.xcscheme")
if errors:
    print("\n".join(errors), file=sys.stderr)
    sys.exit(1)
print(f"PASS: project integrity, {len(app_en)} app + {len(core_en)} core strings in EN/RU")
