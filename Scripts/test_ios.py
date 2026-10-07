#!/usr/bin/env python3
import json
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
devices = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "--json"]))
phones = [device for runtime, group in devices["devices"].items() if ".iOS-" in runtime
          for device in group if device.get("isAvailable") and device["name"].startswith("iPhone")]
if not phones:
    raise SystemExit("No available iPhone simulator. Install an iOS runtime in Xcode Settings > Components.")
destination = phones[0]["udid"]
print(f"Testing on {phones[0]['name']} ({destination})", flush=True)
subprocess.run(["xcodebuild", "-project", "PDFEditor.xcodeproj", "-scheme", "PDFEditor",
                "-destination", "id=" + destination, "-derivedDataPath", "DerivedData",
                "-resultBundlePath", "TestResults.xcresult", "CODE_SIGNING_ALLOWED=NO", "test"], cwd=ROOT, check=True)
