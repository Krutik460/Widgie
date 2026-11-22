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
        let cells = states.map { ($0, "") } + [("empty", "-tinted"), ("full", "-tinted"), ("full", "-dark")]
        let pngs = cells.flatMap { state, suffix in ["small", "medium"].map { "\(state)-\($0)\(suffix).png" } }
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
        #expect(
            renders.compactMap { $0["appearance"] as? String }.suffix(7) == [
                "light", "tinted", "tinted", "tinted", "tinted", "dark", "dark",
            ])
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

    @Test func refineModeWritesTheStoredSourceAndGivesTheBuildersVerdict() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "render-tool-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let water = try fixture("water")
        let path = { (name: String) in directory.appending(path: name).path(percentEncoded: false) }
        let fixturePath = engineDirectory.appending(path: "Fixtures/water").path(percentEncoded: false)

        #expect(await RenderTool.run(["refine", fixturePath, fixturePath, path("same")]) == 0)
        let scratch = Scratch()
        let stored = try #require(try scratch.engine.source(of: try await scratch.build(water)))
        #expect(try WidgetSource(directory: directory.appending(path: "same/current")).json == stored.json)
        #expect(FileManager.default.fileExists(atPath: path("same/full-medium.png")))

        let cups = WidgetSource(
            json: Data(String(decoding: water.json, as: UTF8.self).replacing("\"glasses\"", with: "\"cups\"").utf8))
        try cups.write(to: directory.appending(path: "cups"))
        #expect(await RenderTool.run(["refine", fixturePath, path("cups"), path("renamed")]) == 1)
        let report = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appending(path: "renamed/report.json")))
                as? [String: Any])
        #expect(
            report["verdict"] as? String
                == "table \"glasses\" is gone; keep every table id so the stored rows carry over")
        #expect(await RenderTool.run(["refine", fixturePath, path("cups")]) == 2)
    }

    /// The model sends a refine's JSON without the image bytes, as it got them in `current/`.
    @Test func rejectedRefineDrawsTheNewWidgetWithTheOldWidgetsImages() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "render-tool-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = { (name: String) in directory.appending(path: name).path(percentEncoded: false) }
        let look = counterLook(
            "{ type: 'image', asset: 'photo', frame: { maxWidth: 'infinity', maxHeight: 'infinity' }, cornerRadius: 12 }",
            extra: "{ type: 'text', value: String(ctx.data.n), color: '#FFFFFF', lineLimit: 1 },")
        try document(look: look, assets: ["photo": ["about": "a sunset"]], images: ["photo": photo(300, 200)])
            .write(to: directory.appending(path: "old"))
        #expect(await RenderTool.run(["refine", path("old"), path("old"), path("same")]) == 0)

        let current = try WidgetSource(directory: directory.appending(path: "same/current"))
        let renamed = String(decoding: current.json, as: UTF8.self).replacing("\"taps\"", with: "\"clicks\"")
        try WidgetSource(json: Data(renamed.utf8)).write(to: directory.appending(path: "new"))
        #expect(await RenderTool.run(["refine", path("old"), path("new"), path("renamed")]) == 1)
        let report = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appending(path: "renamed/report.json")))
                as? [String: Any])
        #expect(
            report["verdict"] as? String == "table \"taps\" is gone; keep every table id so the stored rows carry over")
        let pngs = { (name: String) in
            try FileManager.default.contentsOfDirectory(atPath: path(name)).filter { $0.hasSuffix(".png") }.sorted()
        }
        #expect(try pngs("renamed").count == 12)
        #expect(try pngs("renamed") == pngs("same"))
    }

    @Test func renderModeWritesOnePNGAndUsageErrorsExitTwo() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "render-tool-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let water = engineDirectory.appending(path: "Fixtures/water").path(percentEncoded: false)
        let png = directory.appending(path: "full.png")
        #expect(await RenderTool.run([water, "medium", png.path(percentEncoded: false), "--full"]) == 0)
        #expect(FileManager.default.fileExists(atPath: png.path(percentEncoded: false)))
        let tinted = directory.appending(path: "tinted.png")
        #expect(
            await RenderTool.run([water, "small", tinted.path(percentEncoded: false), "--appearance", "tinted"]) == 0)
        #expect(FileManager.default.fileExists(atPath: tinted.path(percentEncoded: false)))
        #expect(await RenderTool.run([water, "small", png.path(percentEncoded: false), "--appearance", "clear"]) == 2)
        #expect(await RenderTool.run([water, "large", png.path(percentEncoded: false)]) == 2)
        #expect(await RenderTool.run([water, "small", png.path(percentEncoded: false), "--bogus"]) == 2)
        #expect(await RenderTool.run(["--help"]) == 0)
    }

    @Test func loopModeExitsTwoWhenTheBridgeDoesNotAnswerOrTheArgumentsAreWrong() async throws {
        let out = FileManager.default.temporaryDirectory.appending(path: "render-tool-\(UUID().uuidString)")
            .path(percentEncoded: false)
        let refused = "http://127.0.0.1:9"
        #expect(await RenderTool.run(["loop", "a water tracker", out, "--bridge", refused]) == 2)
        #expect(!FileManager.default.fileExists(atPath: out))
        #expect(await RenderTool.run(["loop", "a water tracker", out, "--bridge", "localhost"]) == 2)
        #expect(await RenderTool.run(["loop", "a water tracker", out, "--image", "drop.gif"]) == 2)
        #expect(await RenderTool.run(["loop", "a water tracker", out, "--date", "2026-11-18T09:00:00Z"]) == 2)
        #expect(await RenderTool.run(["loop", "a water tracker"]) == 2)
    }
}
