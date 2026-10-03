import XCTest
@testable import HearthCore

final class StateWriterTests: XCTestCase {
    func testQueuedWritesRunOffMainAndTerminationKeepsLatestSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = try LocalStorage(root: root)
        let writer = StateWriter(storage: storage)
        let done = expectation(description: "Background writes completed")
        done.expectedFulfillmentCount = 20
        for index in 0..<20 {
            var state = AppData(); state.selectedModelID = "snapshot-\(index)"
            writer.save(state) { error in
                XCTAssertFalse(Thread.isMainThread)
                XCTAssertNil(error)
                done.fulfill()
            }
        }
        var final = AppData(); final.selectedModelID = "final-snapshot"
        try writer.flush(final)
        await fulfillment(of: [done], timeout: 2)
        XCTAssertEqual(try storage.readState().selectedModelID, "final-snapshot")
    }
}
