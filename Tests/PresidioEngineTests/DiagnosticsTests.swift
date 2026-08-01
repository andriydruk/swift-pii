import Testing
@testable import PresidioEngine

/// A failed resource load degrades silently everywhere in this package — a
/// validator with no table returns `.invalid` for everything, which looks
/// exactly like "nothing matched". This is the check that makes that loud.
@Suite("Diagnostics")
struct DiagnosticsTests {

    @Test("every bundled resource loads with plausible content")
    func allResourcesHealthy() {
        let statuses = Diagnostics.resourceHealth()
        let broken = statuses.filter { !$0.isHealthy }
        #expect(broken.isEmpty, "\(Diagnostics.report())")
        // A shrinking list would silently weaken the check itself.
        #expect(statuses.count == 9, "\(statuses.map(\.resource))")
    }

    @Test("the report names every module and resource")
    func reportIsComplete() {
        let report = Diagnostics.report()
        for module in ["PresidioRecognizers", "PresidioEngine", "PresidioNLP"] {
            #expect(report.contains(module))
        }
        #expect(Diagnostics.allResourcesHealthy)
    }
}
