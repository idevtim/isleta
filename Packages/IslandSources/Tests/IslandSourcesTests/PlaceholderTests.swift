import Testing

@testable import IslandSources

/// Replaced by the per-source suites as Milestones 5–8 land. Present so the test target exists
/// before four sources are written against it in parallel, rather than four agents each inventing
/// a manifest and colliding on the merge.
@Suite("IslandSources")
struct IslandSourcesTests {
    @Test("the package is wired up")
    func packageIsWired() {
        #expect(IslandSources.isImplemented == false)
    }
}
