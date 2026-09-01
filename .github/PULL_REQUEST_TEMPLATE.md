## What does this PR do?


## How to test
1. 
2. 

## Checklist
- [ ] `./Tools/check.sh` passes
- [ ] Tested on real hardware (say which Mac, and whether it has a notch)
- [ ] Read the doc for the area I changed (see [CONTRIBUTING.md](../CONTRIBUTING.md))
- [ ] Updated the relevant doc in this same PR, if the change alters something a doc records
- [ ] No new `print` / `NSLog` / bare `os.Logger` — everything goes through `IslandLog`
- [ ] Nothing the user didn't write gets logged (no track titles, file names, event titles)
- [ ] No inline `.animation(.easeInOut(duration:))` — motion uses the tokens in `IslandUI/Motion.swift`
- [ ] New user-facing strings are localized (en, de, fr, es)
