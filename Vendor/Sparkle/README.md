# Sparkle — licence only

**No Sparkle source or binary is vendored here.** The framework comes from SwiftPM, pinned in
`Isleta.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` (2.9.6 at the time of
writing) and linked into the app target.

What is here is `LICENSE`, copied byte-for-byte from that checkout, because a SwiftPM checkout lives
under `.build/` — untracked, wiped by a clean, and absent on a fresh clone. `Acknowledgements.sparkleMIT`
must be checkable against something that survives all three, and `AcknowledgementTests` compares the
two so they cannot drift.

Refresh this file when Sparkle is upgraded. The test fails if you don't, which is the point.
