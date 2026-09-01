#!/usr/bin/env python3
"""Every key Isleta asks for is translated in every language Isleta claims to speak.

Run by `Tools/check.sh`. It is the *app shell's* coverage test — the shell has no test target, so
without this the one module holding the Sources pane's prose would be the one module nothing checks.
It audits the four packages too, which costs nothing and catches the case their own
`LocalizationCoverageTests` cannot: a language listed in `Config/Isleta-Info.plist` that a package
has no `.lproj` for at all.

**Why the plist is the authority.** Measured on macOS 27.0: CFBundle negotiates a *nested* bundle's
language against the **main** bundle's list, so a package's `de.lproj` is simply never consulted
unless the app itself claims `de`. A language present in a package and absent from
`CFBundleLocalizations` is dead weight that no test in that package can see, and a language present
in the plist and absent from a package is a pane that silently draws English. Both are failures here.

What it does not check is whether a translation is any *good*. Nothing automated can.
"""

from __future__ import annotations

import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
INFO_PLIST = ROOT / "Config" / "Isleta-Info.plist"

# module source directory -> the lookup function whose first argument is a key, and the one file
# that *declares* it. The declaring file is skipped: its doc comment shows the call shape, and the
# scan cannot tell a documented example from a real call.
MODULES = [
    (ROOT / "Packages/IslandActivities/Sources/IslandActivities", "activityText", "ActivityText.swift"),
    (ROOT / "Packages/IslandUI/Sources/IslandUI", "islandText", "IslandText.swift"),
    (ROOT / "Packages/IslandSettings/Sources/IslandSettings", "settingsText", "SettingsText.swift"),
    (ROOT / "Packages/IslandSources/Sources/IslandSources", "sourceText", "SourceText.swift"),
    (ROOT / "Isleta", "appText", "AppText.swift"),
]

# Where each module keeps its tables. A package processes a `Resources` directory; the app target's
# `.lproj` folders are picked up straight out of its file-system-synchronized group.
def resources_directory(module: Path) -> Path:
    return module / "Resources"


# Read through `plutil`, never through Python's `plistlib`, and both halves of that matter.
#
# An old-style `.strings` file is a property list that only CoreFoundation's parser reads —
# `plistlib` does not handle the format at all. And `Config/Isleta-Info.plist` is *XML* that
# `plistlib` still refuses: its comments contain `--` (in "`--perf-report`"), which is illegal
# inside an XML comment by the letter of the spec and which expat rejects, while CoreFoundation
# accepts it and `plutil -lint` calls the file OK. Using the system's own parser means this script
# reads exactly what the running app will read.
def read_plist(path: Path) -> dict[str, object]:
    result = subprocess.run(
        ["plutil", "-convert", "json", "-o", "-", str(path)],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        sys.exit(f"{path.relative_to(ROOT)} is not a readable property list: {result.stderr.strip()}")
    return json.loads(result.stdout)


def shipped_languages() -> list[str]:
    info = read_plist(INFO_PLIST)
    languages = info.get("CFBundleLocalizations")
    if not languages:
        sys.exit("Config/Isleta-Info.plist has no CFBundleLocalizations — no language would resolve")
    # English is the `defaultValue` at every call site and has no `.strings` table.
    return [language for language in languages if language != "en"]


def keys_used(module: Path, function: str, declaring_file: str) -> set[str]:
    pattern = re.compile(rf'{function}\(\s*"((?:[^"\\]|\\.)*)"')
    keys: set[str] = set()
    for path in module.rglob("*.swift"):
        if path.name == declaring_file:
            continue
        keys.update(pattern.findall(path.read_text(encoding="utf-8")))
    return keys


def table(lproj: Path) -> dict[str, object]:
    entries: dict[str, object] = {}
    for name in ("Localizable.strings", "Localizable.stringsdict"):
        path = lproj / name
        if not path.exists():
            continue
        entries.update(read_plist(path))
    return entries


# The printf argument types in a format string, sorted. Sorted rather than in order, because
# reordering the arguments is the main thing a translator is for; what must not differ between two
# languages is the multiset of types, since a %lld translated as %@ reads an integer as a pointer.
ARGUMENT = re.compile(r"%(?:\d+\$)?(lld|ld|lf|[@a-zA-Z])")


def argument_types(value: str) -> list[str]:
    return sorted(ARGUMENT.findall(value))


# The built app carries exactly the languages the source tree describes — and nothing else.
#
# **Measured 2026-08-23, and it is the reason this check exists: neither build system prunes a
# deleted `.lproj`.** After Simplified Chinese was dropped and every `zh-Hans.lproj` removed from the
# source, an incremental `xcodebuild` still produced an `Isleta.app` carrying `zh-Hans.lproj` in its
# own `Contents/Resources` *and* in all four package resource bundles, and `swift build` did the same
# (as `zh-hans.lproj`, lowercased) inside its scratch path. Nothing warns. And a stale folder is not
# inert: `Bundle.localizations` unions the on-disk `.lproj` set with `CFBundleLocalizations`, so the
# retired language is still offered and a user set to it gets whatever half-finished table was left
# behind.
#
# `Tools/release.sh` cannot ship one — it `rm -rf`s its whole build directory before building — so
# this guards the incremental build a developer actually looks at with `--perf-report` and
# `open -a Isleta`, which is where the wrong conclusion would be drawn.
def audit_built_app(app: Path, languages: list[str]) -> list[str]:
    expected = set(languages) | {"en"}
    failures: list[str] = []
    resources = app / "Contents" / "Resources"
    if not resources.is_dir():
        return [f"{app} has no Contents/Resources — is that a built app?"]

    places = [("Isleta.app", resources)]
    places += [(bundle.name, bundle / "Contents" / "Resources")
               for bundle in sorted(resources.glob("*.bundle"))]

    for name, directory in places:
        if not directory.is_dir():
            continue
        # Case-folded: SwiftPM lowercases `zh-Hans.lproj` to `zh-hans.lproj` on the way in, so a
        # case-sensitive comparison reports a language as missing and stale at the same time.
        found = {path.name.removesuffix(".lproj") for path in directory.glob("*.lproj")}
        lowered = {language.lower(): language for language in expected}
        stale = sorted(name for name in found if name.lower() not in lowered)
        if stale:
            failures.append(
                f"{name} carries {', '.join(stale)}.lproj, which the source tree no longer has — "
                "a stale resource from an incremental build. Delete the derived data and build again."
            )
    return failures


def main() -> int:
    languages = shipped_languages()
    failures: list[str] = []

    for module, function, declaring_file in MODULES:
        name = module.name if module.name != "Isleta" else "Isleta (app shell)"
        used = keys_used(module, function, declaring_file)
        resources = resources_directory(module)
        shapes: dict[str, dict[str, list[str]]] = {}

        for language in languages:
            lproj = resources / f"{language}.lproj"
            if not lproj.is_dir():
                failures.append(f"{name}: no {language}.lproj, so that language draws English here")
                continue
            entries = table(lproj)

            missing = sorted(used - entries.keys())
            if missing:
                failures.append(f"{name} [{language}] has no entry for: {', '.join(missing)}")

            stale = sorted(entries.keys() - used)
            if stale:
                failures.append(f"{name} [{language}] has entries nothing asks for: {', '.join(stale)}")

            for key, value in entries.items():
                if isinstance(value, str):
                    shapes.setdefault(key, {})[language] = argument_types(value)

        for key, per_language in shapes.items():
            distinct = {",".join(types) for types in per_language.values()}
            if len(distinct) > 1:
                failures.append(f"{name}: {key} takes different arguments per language: {per_language}")

        print(f"    {name}: {len(used)} keys × {len(languages)} languages")

    # `--built-app <path>` adds the post-build half. Run separately by `Tools/check.sh`, because it
    # can only run *after* the app has been built.
    if "--built-app" in sys.argv:
        app = Path(sys.argv[sys.argv.index("--built-app") + 1])
        built = audit_built_app(app, languages)
        failures.extend(built)
        if not built:
            print(f"    {app.name}: no stale .lproj in the built bundle")

    if failures:
        print("\nlocalization audit failed:", file=sys.stderr)
        for failure in failures:
            print(f"  - {failure}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
