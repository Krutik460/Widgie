import Foundation
import Sandbox
import Testing

private let context = #"{"data":{"count":3},"family":"small","width":158,"height":158}"#

private func run(_ source: String, budget: Sandbox.Budget = .widget) async -> Result<String, Sandbox.Failure> {
    do throws(Sandbox.Failure) {
        return .success(try await Sandbox().run(source, context: context, budget: budget))
    } catch {
        return .failure(error)
    }
}

private func failureLine(_ source: String, budget: Sandbox.Budget = .widget) async -> String? {
    if case .failure(let failure) = await run(source, budget: budget) { failure.line } else { nil }
}

@Suite struct SandboxTests {
    @Test func returnsTheTreeAsJSON() async throws {
        let json = try await run(
            "function render(ctx) { return { type: 'text', value: 'n=' + ctx.data.count, size: ctx.width / 2 }; }"
        ).get()
        #expect(json == #"{"type":"text","value":"n=3","size":79}"#)
    }

    @Test func sameLookAndContextGiveIdenticalBytes() async throws {
        let look = """
            const COLORS = ['#FF0000', '#00FF00'];
            function render(ctx) {
              return { type: 'vstack', children: COLORS.map((c, i) => ({ type: 'rect', fill: c, frame: { width: i * 1.5 } })) };
            }
            """
        let sandbox = Sandbox()
        var outputs: Set<String> = []
        for _ in 0..<5 { outputs.insert(try await sandbox.run(look, context: context, budget: .widget)) }
        #expect(outputs.count == 1)
    }

    @Test func noStateSurvivesBetweenRuns() async throws {
        let look = "var n = (globalThis.n || 0) + 1; globalThis.n = n; function render() { return { n: n }; }"
        let sandbox = Sandbox()
        #expect(try await sandbox.run(look, context: context, budget: .widget) == #"{"n":1}"#)
        #expect(try await sandbox.run(look, context: context, budget: .widget) == #"{"n":1}"#)
    }

    @Test func aThrownErrorNamesItsLine() async {
        let look = """
            function render(ctx) {
              const last = ctx.data.last;
              return { type: 'text', value: last.id };
            }
            """
        let line = await failureLine(look)
        #expect(line?.hasPrefix("look threw TypeError: ") == true)
        #expect(line?.hasSuffix("(line 3)") == true)
    }

    @Test func aSyntaxErrorNamesItsLine() async {
        #expect(
            await failureLine("function render(ctx) {\n  return { type: 'text' value: 'x' };\n}")
                == "look threw SyntaxError: Unexpected identifier 'value'. Expected '}' to end an object literal. (line 2)"
        )
    }

    @Test func aMissingRenderIsNamed() async {
        #expect(
            await failureLine("function draw(ctx) { return {}; }")
                == "look defines no function render(ctx); define it at the top level of the script")
    }

    @Test func renderMayBeAConstArrowFunction() async throws {
        #expect(try await run("const render = (ctx) => ({ type: 'spacer' });").get() == #"{"type":"spacer"}"#)
    }

    @Test func returningNothingIsNamed() async {
        #expect(
            await failureLine("function render(ctx) { if (ctx.data.count > 9) return { type: 'spacer' }; }")
                == "render(ctx) returned undefined; it must return the root node object")
    }

    @Test func aNonFiniteNumberNamesWhereItIs() async {
        let look = "function render(ctx) { return { type: 'vstack', children: [[{ type: 'rect', opacity: 0 / 0 }]] }; }"
        #expect(
            await failureLine(look) == "render(ctx) returned NaN at root.children[0][0].opacity; numbers must be finite"
        )
    }

    @Test func aFunctionInTheTreeIsNamed() async {
        #expect(
            await failureLine("function render() { return { type: 'text', value: () => 1 }; }")
                == "render(ctx) returned a function at root.value; the tree must be plain data")
    }

    @Test(arguments: [
        ("Date.now()", "Date.now() reads the clock"),
        ("new Date()", "Date() reads the clock"),
        ("Date()", "Date() reads the clock"),
        ("Math.random()", "Math.random() is random"),
    ])
    func readingTheClockOrRandomnessFails(_ call: String, _ read: String) async {
        let look = "function render(ctx) {\n  const x = \(call);\n  return { type: 'spacer' };\n}"
        #expect(
            await failureLine(look)
                == "look is not pure: \(read) (line 2); draw from ctx only (ctx.today has the date, and nothing may be random)"
        )
    }

    @Test func catchingAnImpureReadStillFails() async {
        let look = "function render(ctx) {\n  let t = 0;\n  try { t = Date.now(); } catch (e) {}\n  return { t: t };\n}"
        #expect(await failureLine(look)?.hasPrefix("look is not pure: Date.now() reads the clock (line 3)") == true)
    }

    @Test func aClockReadAtTheTopLevelFails() async {
        #expect(
            await failureLine("const seed = Math.random();\nfunction render() { return {}; }")?.hasPrefix(
                "look is not pure: Math.random() is random (line 1)") == true)
    }

    @Test func datesFromFixedValuesStillWork() async throws {
        let look = "function render() { return { d: new Date(Date.UTC(2026, 10, 18)).toISOString().slice(0, 10) }; }"
        #expect(try await run(look).get() == #"{"d":"2026-11-18"}"#)
    }

    @Test func anEndlessLoopTimesOutAndTheNextRunStillWorks() async throws {
        let sandbox = Sandbox()
        let started = ContinuousClock.now
        do throws(Sandbox.Failure) {
            _ = try await sandbox.run(
                "function render() { while (true) {} }", context: context,
                budget: Sandbox.Budget(time: .milliseconds(50))
            )
            Issue.record("an endless loop returned")
        } catch {
            #expect(
                error.line == "look ran longer than 50 ms; render(ctx) must finish quickly, so look for an endless loop"
            )
        }
        #expect(ContinuousClock.now - started < .seconds(2))
        #expect(
            try await sandbox.run("function render() { return {}; }", context: context, budget: .widget) == "{}")
    }

    @Test func anEndlessLoopAtTheTopLevelTimesOut() async {
        #expect(
            await failureLine(
                "while (true) {}\nfunction render() { return {}; }", budget: .init(time: .milliseconds(50)))
                == "look ran longer than 50 ms; render(ctx) must finish quickly, so look for an endless loop")
    }

    @Test func concurrentRunsOnOneSandboxDoNotInterfere() async throws {
        let sandbox = Sandbox()
        let results = try await withThrowingTaskGroup(of: String.self) { group in
            for n in 0..<8 {
                group.addTask {
                    try await sandbox.run(
                        "function render() { let s = 0; for (let i = 0; i < 20000; i++) s += i; return { n: \(n), s: s }; }",
                        context: context, budget: .widget)
                }
            }
            return try await group.reduce(into: Set<String>()) { $0.insert($1) }
        }
        #expect(results == Set((0..<8).map { #"{"n":\#($0),"s":199990000}"# }))
    }
}
