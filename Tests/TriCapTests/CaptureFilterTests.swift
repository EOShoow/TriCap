import CoreGraphics
import Testing
@testable import CaptureCore

@Suite("Capture self-window exceptions")
struct CaptureFilterTests {

    @Test("Production captures include no TriCap windows by default")
    func productionDefaultHasNoExceptions() {
        let result = CaptureConfiguration.validatedOwnWindowExceptionIDs(
            requested: [],
            availableOwnWindowIDs: [10, 20]
        )
        #expect(result.isEmpty)
    }

    @Test("Only an explicitly requested TriCap window can bypass self-exclusion")
    func exceptionIsNarrowlyScoped() {
        let result = CaptureConfiguration.validatedOwnWindowExceptionIDs(
            requested: [20, 99],
            availableOwnWindowIDs: [10, 20]
        )
        #expect(result == Set<CGWindowID>([20]))
    }
}
