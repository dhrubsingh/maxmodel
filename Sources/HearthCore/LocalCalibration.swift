import Foundation

public struct LocalAnswerCheck: Codable, Equatable, Sendable {
    public let name: String
    public let passed: Bool
    public init(name: String, passed: Bool) { self.name = name; self.passed = passed }
}

/// Small deterministic sanity checks, deliberately not advertised as an intelligence
/// benchmark. Prompts are synthetic; no chats/files are read or uploaded.
public enum LocalCalibration {
    public struct Task: Sendable {
        public let name: String
        public let prompt: String
        public let expected: String
    }
    public static let version = "sanity-v1"
    public static let tasks: [Task] = [
        Task(name: "Follow a short instruction", prompt: "Reply with exactly the word lantern in lowercase. No punctuation or other words.", expected: "lantern"),
        Task(name: "Calculate a result", prompt: "A shelf has 17 books. You add 8 and lend 6. How many books remain? Reply with only the integer.", expected: "19"),
        Task(name: "Read supplied facts", prompt: "Use only these facts: Mira's box is green. Leon's box is amber. The green box contains 4 keys. What color is Leon's box? Reply with one lowercase word.", expected: "amber"),
        Task(name: "Avoid inventing a fact", prompt: "Use only this note: 'The museum opens on Saturday.' At what time does it open? If the note does not say, reply with exactly UNKNOWN. Do not guess.", expected: "UNKNOWN"),
        Task(name: "Keep track of order", prompt: "Ana arrived before Bo. Cy arrived after Bo. Who arrived second? Reply with only the name.", expected: "Bo"),
        Task(name: "Return structured data", prompt: "Return only a JSON object with exactly two keys: color with the string blue, and count with the number 3. No markdown.", expected: "json")
    ]
    public static func passes(_ answer: String, task: Task) -> Bool {
        let value = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        if task.expected == "json" {
            guard let data = value.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
            return object.count == 2 && object["color"] as? String == "blue" && (object["count"] as? NSNumber)?.stringValue == "3"
        }
        return value == task.expected
    }
}
