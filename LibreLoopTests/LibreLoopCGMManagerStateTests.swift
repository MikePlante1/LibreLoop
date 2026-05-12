import XCTest
@testable import LibreLoop

final class LibreLoopCGMManagerStateTests: XCTestCase {
    func testRawValueRoundTrip() {
        var state = LibreLoopCGMManagerState()
        state.sensorSerial = "ABC123"
        state.activatedAt = Date(timeIntervalSince1970: 1_700_000_000)

        let raw = state.rawValue
        guard let restored = LibreLoopCGMManagerState(rawValue: raw) else {
            return XCTFail("Failed to restore state from rawValue")
        }

        XCTAssertEqual(restored.sensorSerial, state.sensorSerial)
        XCTAssertEqual(restored.activatedAt, state.activatedAt)
    }
}
