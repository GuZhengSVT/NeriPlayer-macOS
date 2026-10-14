#!/usr/bin/env python3
"""Check the packaged Mach-O closure before signing or advertising an OS target."""
import argparse
import json
import plistlib
import re
import subprocess
from pathlib import Path


def version(value):
    return tuple(int(part) for part in value.split(".")) + (0,) * (3 - len(value.split(".")))


def minimum_os(binary):
    output = subprocess.check_output(["xcrun", "vtool", "-show-build", str(binary)], text=True)
    values = re.findall(r"^\s*minos\s+([0-9.]+)\s*$", output, re.MULTILINE)
    # Older dylibs use LC_VERSION_MIN_MACOSX instead of LC_BUILD_VERSION.
    values += re.findall(r"cmd LC_VERSION_MIN_MACOSX\s+cmdsize \d+\s+version ([0-9.]+)", output)
    if not values:
        raise ValueError(f"cannot determine macOS minimum: {binary}")
    return max(values, key=version)


def dependencies(binary, executable, frameworks):
    output = subprocess.check_output(["otool", "-L", str(binary)], text=True)
    missing = []
    for line in output.splitlines():
        if " (compatibility version " not in line:
            continue
        reference = line.strip().split(" (compatibility version ", 1)[0]
        if reference.startswith(("/usr/lib/", "/System/Library/", "/System/iOSSupport/")):
            continue
        if reference.startswith("@rpath/"):
            target = frameworks / reference.removeprefix("@rpath/")
        elif reference.startswith("@loader_path/"):
            target = binary.parent / reference.removeprefix("@loader_path/")
        elif reference.startswith("@executable_path/"):
            target = executable.parent / reference.removeprefix("@executable_path/")
        else:
            missing.append(reference + " (external non-system dependency)")
            continue
        if not target.is_file():
            missing.append(reference + " (missing packaged file)")
    return missing


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--minimum", default="27.0", help="required deployment minimum, or auto for local validation")
    parser.add_argument("--write-minimum", action="store_true")
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()
    plist_path = args.app / "Contents/Info.plist"
    info = plistlib.loads(plist_path.read_bytes())
    executable = args.app / "Contents/MacOS" / info["CFBundleExecutable"]
    frameworks = args.app / "Contents/Frameworks"
    binaries = [executable] + sorted(path for path in frameworks.rglob("*.dylib") if path.is_file())
    entries = []
    for binary in binaries:
        entries.append({"path": str(binary.relative_to(args.app)), "minimum": minimum_os(binary),
                        "missing": dependencies(binary, executable, frameworks)})
    actual = max((entry["minimum"] for entry in entries), key=version)
    target = actual if args.minimum == "auto" else args.minimum
    errors = [entry for entry in entries if version(entry["minimum"]) > version(target) or entry["missing"]]
    report = {"requested": args.minimum, "effectiveMinimum": actual, "declaredMinimum": target,
              "passed": not errors, "binaries": entries}
    if args.report:
        args.report.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")
    for entry in errors:
        print(f"incompatible: {entry['path']} requires {entry['minimum']}; target {target}")
        for missing in entry["missing"]:
            print(f"  {missing}")
    if errors:
        print("Use dependencies rebuilt for the target OS. Do not rewrite Mach-O minimums to pretend compatibility.")
        return 1
    if args.write_minimum:
        info["LSMinimumSystemVersion"] = target
        plist_path.write_bytes(plistlib.dumps(info))
    print(f"compatibility PASS: {len(entries)} binaries, minimum macOS {actual}, declared {target}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
