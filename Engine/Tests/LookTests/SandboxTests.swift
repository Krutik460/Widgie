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
                == "look threw SyntaxError: Unexpected identifier 'value' (line 2)"
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
        ("performance.now()", "performance.now() reads the clock"),
        ("performance.timeOrigin", "performance.timeOrigin reads the clock"),
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

    @Test func anEndlessLoopStopsAtTheStepBudgetAndTheNextRunStillWorks() async throws {
        let sandbox = Sandbox()
        let started = ContinuousClock.now
        do throws(Sandbox.Failure) {
            _ = try await sandbox.run(
                "function render() { while (true) {} }", context: context,
                budget: Sandbox.Budget(steps: 50, memory: Sandbox.Budget.widget.memory)
            )
            Issue.record("an endless loop returned")
        } catch {
            #expect(
                error.line
                    == "look ran longer than 50 steps; render(ctx) must finish quickly, so look for an endless loop"
            )
        }
        #expect(ContinuousClock.now - started < .seconds(2))
        #expect(
            try await sandbox.run("function render() { return {}; }", context: context, budget: .widget) == "{}")
    }

    @Test func anEndlessLoopAtTheTopLevelStops() async {
        #expect(
            await failureLine("while (true) {}\nfunction render() { return {}; }")
                == "look ran longer than 2000 steps; render(ctx) must finish quickly, so look for an endless loop")
    }

    @Test func catchingTheStopDoesNotHelp() async {
        let look = "function render() { for (;;) { try { while (true) {} } catch (e) {} } }"
        #expect(await failureLine(look)?.hasPrefix("look ran longer than 2000 steps") == true)
    }

    @Test func aGetterOnAThrownValueCannotRunForever() async {
        let look = "function render() { throw { get name() { for (;;) {} } }; }"
        #expect(await failureLine(look)?.hasPrefix("look ran longer than 2000 steps") == true)
    }

    @Test func theStepCountIsTheSameEveryRun() async throws {
        let look = "function render() { let s = 0; for (let i = 0; i < 1000000; i++) s += i; return { s }; }"
        let sandbox = Sandbox()
        func passes(_ steps: Int) async -> Bool {
            (try? await sandbox.run(look, context: context, budget: .init(steps: steps, memory: 12 << 20))) != nil
        }
        var low = 1
        var high = 1000
        while low < high {
            let middle = (low + high) / 2
            if await passes(middle) { high = middle } else { low = middle + 1 }
        }
        // A million turns of the loop take about 200 steps; the exact count is the same on every run, so the
        // verdict flips at one budget and never wavers around it.
        #expect((100...400).contains(low))
        for _ in 0..<5 {
            #expect(await passes(low))
            #expect(await !passes(low - 1))
        }
    }

    @Test func noRunLeavesAThreadBehind() async throws {
        let sandbox = Sandbox()
        for _ in 0..<3 {
            _ = try? await sandbox.run(
                "function render() { while (true) {} }", context: context,
                budget: Sandbox.Budget(steps: 20, memory: Sandbox.Budget.widget.memory))
        }
        // Other tests run looks in parallel, so wait for one moment with no run thread alive at all. With an
        // engine that abandons a spinning thread, that moment never comes.
        let deadline = ContinuousClock.now + .seconds(10)
        var sawNone = lookThreads() == 0
        while !sawNone && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
            sawNone = lookThreads() == 0
        }
        #expect(sawNone)
    }

    @Test func aTreeThatContainsItselfIsNamed() async {
        let look =
            "function render() {\n  const t = { type: 'vstack', a: 1, b: 2, c: 3 };\n  t.children = [t, t, t];\n  return t;\n}"
        let line = await failureLine(look, budget: .proof)
        #expect(
            line?.hasPrefix("render(ctx) returned data nested more than 200 levels at root.children[0].children[0]")
                == true)
        #expect(line?.hasSuffix(".children[0].type; the tree must not contain itself") == true)
    }

    @Test func aLookThatAllocatesWithoutBoundRunsOutOfMemory() async throws {
        let look = "function render() { const a = []; for (;;) a.push('x'.repeat(1000) + a.length); }"
        #expect(
            await failureLine(look)
                == "look used more than 12 MB of memory; render(ctx) must build a small tree, so look for a loop that keeps growing an array or string"
        )
        let sandbox = Sandbox()
        _ = try? await sandbox.run(look, context: context, budget: .proof)
        #expect(try await sandbox.run("function render() { return {}; }", context: context, budget: .proof) == "{}")
    }

    @Test func oneHugeAllocationRunsOutOfMemory() async {
        #expect(
            await failureLine("function render() { return { s: 'x'.repeat(1 << 28) }; }", budget: .proof)?.hasPrefix(
                "look used more than 8 MB of memory") == true)
    }

    @Test func catchingRunningOutOfMemoryStillFails() async {
        let look = "function render() {\n  try { 'x'.repeat(1 << 28); } catch (e) {}\n  return { type: 'spacer' };\n}"
        #expect(await failureLine(look, budget: .proof)?.hasPrefix("look used more than 8 MB of memory") == true)
    }

    @Test func aRegularExpressionThatBacktracksForeverStops() async {
        let look = "function render() { return { v: /(a+)+$/.test('a'.repeat(40) + 'b') }; }"
        #expect(await failureLine(look)?.hasPrefix("look ran longer than 2000 steps") == true)
    }

    @Test func sourceNestedTooDeepToParseThrows() async {
        let nested = String(repeating: "(", count: 100_000) + "1" + String(repeating: ")", count: 100_000)
        #expect(
            await failureLine("function render() { return { v: \(nested) }; }")
                == "look threw RangeError: Maximum call stack size exceeded")
    }

    @Test func deepRecursionThrowsInsteadOfCrashing() async {
        let look = "function down(n) {\n  return down(n + 1) + 1;\n}\nfunction render() { return { n: down(0) }; }"
        #expect(await failureLine(look) == "look threw RangeError: Maximum call stack size exceeded (line 2)")
    }

    @Test func aTreeNestedTwoHundredLevelsStillFits() async throws {
        let look = "function render() { let t = {}; for (let i = 0; i < 199; i++) t = { c: t }; return t; }"
        #expect(try await run(look).get().count == 199 * 6 + 2)
    }

    @Test func throwingSomethingThatIsNotAnErrorIsNamed() async {
        #expect(await failureLine("function render() {\n  throw null;\n}") == "look threw null")
        #expect(await failureLine("function render() {\n  throw 'nope';\n}") == "look threw nope")
    }

    @Test func changedBuiltInsDoNotReachTheNextRun() async throws {
        let sandbox = Sandbox()
        let vandal = """
            Array.prototype.map = null;
            Object.prototype.extra = 1;
            JSON.stringify = function () { return '"hijacked"'; };
            function render() { return {}; }
            """
        _ = try? await sandbox.run(vandal, context: context, budget: .widget)
        let look = "function render() { return { a: [1, 2].map((x) => x * 2), extra: ({}).extra === undefined }; }"
        #expect(try await sandbox.run(look, context: context, budget: .widget) == #"{"a":[2,4],"extra":true}"#)
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

/// Threads named like the sandbox's run thread that are alive in this process, or nil when the list is unreadable.
private func lookThreads() -> Int? {
    var list: thread_act_array_t?
    var count: mach_msg_type_number_t = 0
    guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS, let list else { return nil }
    defer {
        for index in 0..<Int(count) { mach_port_deallocate(mach_task_self_, list[index]) }
        vm_deallocate(
            mach_task_self_, vm_address_t(UInt(bitPattern: list)), vm_size_t(Int(count) * MemoryLayout<thread_t>.stride)
        )
    }
    var found = 0
    for index in 0..<Int(count) {
        guard let thread = pthread_from_mach_thread_np(list[index]) else { continue }
        var name = [CChar](repeating: 0, count: 64)
        pthread_getname_np(thread, &name, name.count)
        let bytes = name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        if String(decoding: bytes, as: UTF8.self) == "look" { found += 1 }
    }
    return found
}
