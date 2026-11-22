import Foundation
import Testing
import WidgetBuilder

/// The build loop against a scripted model: what it sends the model, what it saves, and what it reports.
@Suite struct LoopTests {
    @Test func aReplyWithProseAroundTheFenceOrTwoFencesGivesTheDocumentThePythonHarnessTakes() throws {
        struct Case: Decodable {
            let name: String
            let reply: String
            let document: String
        }
        let file = engineDirectory.appending(path: "Evals/testdata/extract.json")
        let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: file))
        #expect(cases.contains { $0.name == "a json fence with prose around it" })
        #expect(cases.contains { $0.name == "the json fence wins over a longer fence of another kind" })
        for item in cases {
            let extracted = extractDocument(item.reply)
            #expect(
                Array(extracted.unicodeScalars) == Array(item.document.unicodeScalars),
                "\(item.name): got \(extracted.debugDescription)")
        }
    }
}
