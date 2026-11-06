#!/bin/bash
# Lists the user-facing strings the code uses that Localization/<lang>.lproj/Localizable.strings does not translate.
#
# The keys come from the compiler (-emit-localized-strings), the same list Xcode builds a String Catalog from: every
# literal passed as a LocalizedStringKey (Text("…"), Button("…"), .help("…"), …) or String.LocalizationValue
# (String(localized: "…"), ToastHUDController.show(message:), DestructiveConfirmation.confirm(title:…)), with its
# interpolations already turned into %@ / %lld. A String passed to Text(_:) is shown as it is and is not listed.
#
# Usage: scripts/check_localization.sh [lang]     (default: vi)
# Exit status: 0 when nothing is missing, 1 otherwise. It builds twice from scratch in a temporary folder (~1.5 min).
set -euo pipefail

LANG_CODE="${1:-vi}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TABLE="$ROOT/Localization/$LANG_CODE.lproj/Localizable.strings"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/zenith-l10n.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

cd "$ROOT"
# Two builds, because ZenithApp and ZenithCore both have a MenuBarController.swift (and a few more) and the compiler
# names its output after the file: built together, one target's strings overwrite the other's.
swift build --product Zenith --scratch-path "$WORK/app-build" \
    -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$WORK/app" >/dev/null
swift build --target ZenithCore --scratch-path "$WORK/core-build" \
    -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$WORK/core" >/dev/null

python3 - "$WORK" "$TABLE" <<'PY'
import glob, json, os, sys

work, table_path = sys.argv[1], sys.argv[2]
keys = {}
for folder, only_core in ((os.path.join(work, "app"), False), (os.path.join(work, "core"), True)):
    for path in sorted(glob.glob(os.path.join(folder, "*.stringsdata"))):
        data = json.load(open(path))
        source = data.get("source", "")
        if only_core and "/ZenithCore/" not in source:
            continue
        # Made-up data for screenshots and the command-line help are not part of the UI.
        if source.endswith("ScreenshotRenderer.swift") or source.endswith("/main.swift"):
            continue
        for entries in data.get("tables", {}).values():
            for entry in entries:
                if entry["key"]:
                    keys.setdefault(entry["key"], f'{os.path.basename(source)}:{entry["location"]["startingLine"]}')

if not os.path.exists(table_path):
    print(f"No table at {table_path}")
    sys.exit(1)
import subprocess
table = json.loads(subprocess.run(["plutil", "-convert", "json", "-o", "-", table_path],
                                  capture_output=True, text=True, check=True).stdout)
missing = sorted(k for k in keys if k not in table)
unused = sorted(k for k in table if k not in keys)
print(f"{len(keys)} strings in the code, {len(table)} in {os.path.relpath(table_path)}")
for key in missing:
    print(f"  missing: {key!r}  ({keys[key]})")
for key in unused:
    print(f"  no longer used: {key!r}")
sys.exit(1 if missing else 0)
PY
