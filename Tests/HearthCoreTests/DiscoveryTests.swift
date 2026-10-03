import XCTest
@testable import HearthCore

final class DiscoveryTests: XCTestCase {
    func testPicksAreDistinctAndRespectMemoryAndStorage() throws {
        let catalog = try LocalModel.catalog()
        let roomy = Hardware(chip: "M4", cores: 10, memory: 16 << 30, gpu: "M4", gpuWorkingSet: 12 << 30, freeDisk: 50 << 30, architecture: "Apple Silicon")
        let picks = Discovery.picks(catalog: catalog, hardware: roomy, installed: [])
        XCTAssertEqual(picks.count, 3)
        XCTAssertEqual(Set(picks.map(\.id)).count, picks.count)
        XCTAssertTrue(picks.allSatisfy { roomy.fit($0.model) != .tight && $0.model.parameters >= 1 })
        XCTAssertLessThan(picks[1].model.bytes, picks[0].model.bytes)
        let full = Hardware(chip: "M4", cores: 10, memory: 16 << 30, gpu: "M4", gpuWorkingSet: 12 << 30, freeDisk: 0, architecture: "Apple Silicon")
        XCTAssertTrue(Discovery.picks(catalog: catalog, hardware: full, installed: []).isEmpty)
        XCTAssertEqual(Discovery.picks(catalog: catalog, hardware: full, installed: ["qwen3-4b"]).map(\.id), ["qwen3-4b"])
    }
    func testExamplesMatchExactWeightsAndUseIdenticalPrompts() throws {
        let catalog = try LocalModel.catalog()
        let archive = try DiscoveryExamples.load(catalog: catalog)
        XCTAssertEqual(Set(archive.examples.map(\.modelID)).count, 3)
        for promptID in Set(archive.examples.map(\.promptID)) {
            let examples = archive.examples.filter { $0.promptID == promptID }
            XCTAssertEqual(examples.count, 3)
            XCTAssertEqual(Set(examples.map(\.prompt)).count, 1)
            XCTAssertTrue(examples.allSatisfy { !$0.reachedLimit && !$0.answer.isEmpty })
        }
    }
}
