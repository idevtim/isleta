import AppKit
import IOKit.hidsystem
import IslandSources

/// Watches for a **real** media key and reports whether Isleta's own monitor saw it.
///
/// **The one fact about the rebound's repeat that no unit test can settle.** `MediaKeyTests` proves
/// the decoding and the policy against synthesised events; whether the events *arrive at all* is a
/// question about this OS and this machine's grants.
///
/// **It waits for a human rather than posting one, and that is the whole design.** The first version
/// synthesised a subtype-8 key and concluded from silence that the route was dead — walking straight
/// into the trap `DisplayServicesBrightnessMonitor` already records: synthesised media keys "are
/// consumed below the event-tap layer" on Apple Silicon, so an absence proves nothing. That note
/// ends "any future measurement has to be driven by a real keypress", and this is that.
///
/// TCC judges a request against the *responsible* process, so run the built app with `open -a`:
///
///     open -a Isleta.app --args --media-key-test --no-sources
///     log show --predicate 'process == "Isleta"' --last 1m | grep "media key self-test"
///
/// Run from a shell instead, it answers about Terminal's grants and not Isleta's.
@MainActor
enum MediaKeySelfTest {

    static func isRequested() -> Bool {
        ProcessInfo.processInfo.arguments.contains("--media-key-test")
    }

    /// How long to hold the door open for somebody to press a key. Long enough to read the prompt,
    /// reach the keyboard and press twice.
    private static let window: TimeInterval = 15

    static func run(completion: @escaping @MainActor (String) -> Void) {
        let trusted = AXIsProcessTrusted()
        let monitor = MediaKeyMonitor()
        var seen: [MediaKey] = []
        monitor.start { key in seen.append(key) }
        let tapped = monitor.isAvailable

        // The other route, watched side by side, because "which of the two works" is the question
        // this test exists to answer once rather than to be re-litigated later. `MediaKeyMonitor`
        // records why the tap is the one that ships.
        var viaMonitor: [String] = []
        let global = NSEvent.addGlobalMonitorForEvents(matching: .systemDefined) { event in
            MainActor.assumeIsolated {
                if let key = MediaKeyMonitorProbe.mediaKey(in: event) { viaMonitor.append(key) }
            }
        }

        print("""
            media key self-test: listening for \(Int(window))s.
                              **Press the volume up or down key now**, a few times.
                              accessibility: \(trusted), event tap created: \(tapped)
            """)

        DispatchQueue.main.asyncAfter(deadline: .now() + window) {
            MainActor.assumeIsolated {
                monitor.stop()
                if let global { NSEvent.removeMonitor(global) }

                let lines = [
                    "accessibility: \(trusted)",
                    "event tap created: \(tapped)",
                    "keys via the event tap: \(seen.isEmpty ? "none" : seen.map(\.rawValue).joined(separator: ", "))",
                    "keys via a global NSEvent monitor: \(viaMonitor.isEmpty ? "none" : viaMonitor.joined(separator: ", "))",
                ]
                let verdict: String
                if !seen.isEmpty {
                    verdict = "PASS — media keys reach the event tap, so the rebound repeats while a "
                        + "level key is held at its end."
                } else if !viaMonitor.isEmpty {
                    verdict = "FAIL — the tap saw nothing but a global monitor did. `MediaKeyMonitor` "
                        + "is on the wrong route; swap it back."
                } else if !tapped {
                    verdict = "FAIL (expected) — the event tap was refused, which is Accessibility "
                        + "not being granted to Isleta. The island still rebounds when a level "
                        + "*reaches* an end; it will not repeat while the key is held."
                } else {
                    verdict = "INCONCLUSIVE — nothing arrived on either route. Either no key was "
                        + "pressed during the window, or media keys are not readable here at all."
                }
                completion(([verdict] + lines).joined(separator: "\n                  "))
            }
        }
    }
}

/// The decoder, reached from the app shell for the side-by-side above. `MediaKeyMonitor` owns it;
/// this is the one caller outside IslandSources and it exists only for the test.
private enum MediaKeyMonitorProbe {
    static func mediaKey(in event: NSEvent) -> String? {
        guard event.type == .systemDefined,
              event.subtype.rawValue == Int16(NX_SUBTYPE_AUX_CONTROL_BUTTONS) else { return nil }
        let keyCode = Int32((event.data1 & 0xFFFF_0000) >> 16)
        let isDown = ((event.data1 & 0x0000_FFFF) & 0xFF00) >> 8 == 0x0A
        guard isDown else { return nil }
        return switch keyCode {
        case NX_KEYTYPE_SOUND_UP: "volumeUp"
        case NX_KEYTYPE_SOUND_DOWN: "volumeDown"
        case NX_KEYTYPE_BRIGHTNESS_UP: "brightnessUp"
        case NX_KEYTYPE_BRIGHTNESS_DOWN: "brightnessDown"
        default: nil
        }
    }
}
