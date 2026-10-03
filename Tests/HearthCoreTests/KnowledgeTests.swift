import XCTest
@testable import HearthCore

final class KnowledgeTests: XCTestCase {
    func testCutoffsHaveProvenanceAndKeepPublisherPrecision() throws {
        let catalog = try LocalModel.catalog()
        for model in catalog {
            let knowledge = try XCTUnwrap(model.knowledge, model.id)
            XCTAssertEqual(knowledge.sourceURL.scheme, "https")
            XCTAssertFalse(knowledge.note.isEmpty)
            XCTAssertFalse(knowledge.checkedAt.isEmpty)
        }
        let byID = Dictionary(uniqueKeysWithValues: catalog.map { ($0.id, $0) })
        XCTAssertEqual(byID["gemma4-e2b"]?.knowledgeCutoffLabel, "January 2025")
        XCTAssertEqual(byID["phi4-14b"]?.knowledgeCutoffLabel, "June 2024 or earlier")
        XCTAssertEqual(byID["lfm25-230m"]?.knowledgeCutoffLabel, "Mid-2024")
        // No dates inferred from names, release months, related models, or chat answers.
        for id in ["qwen3-4b", "qwen3-instruct-4", "lfm25-2.6b", "deepseek-r1-0528"] {
            XCTAssertNil(byID[id]?.knowledge?.cutoff)
            XCTAssertEqual(byID[id]?.knowledgeCutoffLabel, "Not documented")
        }
    }

    func testMissingKnowledgeInOlderCatalogStillDecodesAsUnknown() throws {
        let model = try XCTUnwrap(LocalModel.catalog().first)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(model)) as? [String: Any])
        object.removeValue(forKey: "knowledge")
        let decoded = try JSONDecoder().decode(LocalModel.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.knowledge)
        XCTAssertEqual(decoded.knowledgeCutoffLabel, "Not documented")
    }
}
