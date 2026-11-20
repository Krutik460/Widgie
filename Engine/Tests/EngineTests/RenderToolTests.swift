import Foundation
import Testing
import WidgetBuilder
import WidgetEngine

@testable import RenderTool

/// The command line, run in process through the same function `main` calls. Proof mode leaves its output in
/// `.artifacts/proof/<fixture>/` for people to look at.
@Suite struct RenderToolTests {
    @Test(arguments: fixtureNames)
    func proofModeAcceptsEachFixtureAndWritesEveryRender(_ name: String) async throws {
        let output = engineDirectory.appending(path: ".artifacts/proof/\(name)")
        try? FileManager.default.removeItem(at: output)
        let status = await RenderTool.run([
            "proof", engineDirectory.appending(path: "Fixtures/\(name)").path(percentEncoded: false),
            output.path(percentEncoded: false), "--date", "2026-11-18T09:00:00Z",
        ])
        #expect(status == 0)

        let samples = try JSONSerialization.jsonObject(with: try fixture(name).json) as? [String: Any]
        let names = ((samples?["samples"] as? [String: Any]) ?? [:]).keys.sorted()
        let states = ["empty"] + names.map { "sample-" + $0.replacing(" ", with: "-") } + ["full"]
        let pngs = states.flatMap { state in ["small", "medium"].map { "\(state)-\($0).png" } }
        let written = try FileManager.default.contentsOfDirectory(atPath: output.path(percentEncoded: false))
        #expect(Set(written) == Set(pngs + ["report.json"]))

        let report = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: output.appending(path: "report.json")))
                as? [String: Any])
        #expect(report["verdict"] is NSNull)
        #expect(report["timeZone"] as? String == "UTC")
        let renders = try #require(report["renders"] as? [[String: Any]])
        #expect(renders.compactMap { $0["png"] as? String } == pngs)
        #expect(renders.allSatisfy { $0["verdict"] is NSNull && $0["error"] is NSNull && $0["fit"] is [String: Any] })
    }

    @Test func proofModeExitsOneWithTheBuildLineForARejectedWidget() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "render-tool-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try Broken.blank.write(to: directory.appending(path: "widget"))
        let status = await RenderTool.run([
            "proof", directory.appending(path: "widget").path(percentEncoded: false),
            directory.appending(path: "out").path(percentEncoded: false),
        ])
        #expect(status == 1)
        let report = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appending(path: "out/report.json")))
                as? [String: Any])
        #expect(report["verdict"] as? String == (try await Scratch().line(Broken.blank)))
    }

    @Test func renderModeWritesOnePNGAndUsageErrorsExitTwo() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "render-tool-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let water = engineDirectory.appending(path: "Fixtures/water").path(percentEncoded: false)
        let png = directory.appending(path: "full.png")
        #expect(await RenderTool.run([water, "medium", png.path(percentEncoded: false), "--full"]) == 0)
        #expect(FileManager.default.fileExists(atPath: png.path(percentEncoded: false)))
        #expect(await RenderTool.run([water, "large", png.path(percentEncoded: false)]) == 2)
        #expect(await RenderTool.run([water, "small", png.path(percentEncoded: false), "--bogus"]) == 2)
        #expect(await RenderTool.run(["--help"]) == 0)
    }
}
