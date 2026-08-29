import CoreGraphics
import Testing
@testable import SelectionUI

@Suite("Selection overlay placement")
struct SelectionOverlayPlacementTests {

    @Test("A secondary display origin is not applied twice")
    func secondaryDisplayUsesLocalInitializerCoordinates() {
        let screenFrame = CGRect(x: -1280, y: 156, width: 1280, height: 800)

        #expect(
            SelectionOverlayPlacement.contentRect(forScreenFrame: screenFrame)
                == CGRect(x: 0, y: 0, width: 1280, height: 800)
        )
    }
}
