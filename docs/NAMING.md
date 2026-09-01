# Naming

Plain English, and never anyone else's.

Extracted from `CLAUDE.md`, which now carries the map rather than the record.

---

**Isleta names its features in plain descriptive English, and coins nothing.** Decision 2026-08-23,
and it is a product rule before it is a legal one: §the bar says a Mac user cannot tell this isn't an
Apple feature, and Apple does not brand its sub-features with portmanteaus. There is no "Live
Activities" equivalent to invent here — there is Now Playing, the shelf, the glance, drop actions,
system HUDs. Every one of those is what the thing *is*, which is why they read as macOS and why they
need no glossary.

**Do not use a competitor's product vocabulary for one of our features, in code, in a UI string, in a
`UserDefaults` key, or in a test name.** DynamicLake's module names — DynaKeys, DynaMusix,
DynaGlance, DynaClip, DynaDrop, DynaConnect, DynaSwitcher, DynaCall, DynaBoats, Liqoria, miniLake,
Slim Player — and Alcove's are theirs. They are catalogued in an unpublished competitive analysis,
because naming the thing you are comparing against is what analysis is; a stage in `PROGRESS.md`
or a symbol in the source is a different act.

One had reached the code: **`miniLake` shipped as an `AppearanceSettings` field, a `UserDefaults`
key, a test suite and a user-facing switch label.** It became `compactIsland` at schema 12, with
`migrateV11ToV12` carrying the value across, and the setting itself went at schema 18 along with the
rest of the Appearance pane — the open island takes one height now. The episode is what the rule is
for and it stands whether or not the field survived.

**A new feature gets a name that says what it does, in the words a user would use.** "Copy link", not
a coinage. "Drop history", not a coinage. If a name needs a sentence to explain it, it is the wrong
name — and if it reads like a brand, it is somebody else's.
