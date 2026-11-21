import CQuickJS
import Foundation

/// The JavaScript engine boundary. Strings in, string out: the look source, the context as JSON text, and the
/// tree as JSON text. The engine is QuickJS-ng, vendored as the C target `CQuickJS`; nothing outside this file
/// knows that. It is a concrete type, not a protocol, because only one engine ships.
///
/// Per run: a fresh QuickJS runtime and context, freed before the run returns, so no state survives between
/// renders and no memory is shared. Before the look loads, a prelude replaces `Math.random`, `Date.now`,
/// `Date()`, argument-less `new Date()`, and QuickJS's `performance` clock with functions that record the read and throw, so impurity fails
/// every proof instead of flickering, even when the look catches the error. The tree is serialized inside the
/// engine with `JSON.stringify` after a walk that rejects what JSON cannot carry: functions, non-finite numbers,
/// and a tree that contains itself. The sandbox knows nothing about the node vocabulary; flattening `children`
/// and every other rule of the tree belong to the validator.
///
/// Budget: steps and bytes, never time, so a look gets the same verdict on the Mac that proves it and on the
/// phone that renders it. QuickJS calls an interrupt handler once every 10,000 interpreter checkpoints (a
/// checkpoint is a backward jump, a call, or a turn of a loop inside some built-ins, like `Array.prototype.map`).
/// One step is one handler call. The count starts at zero for every run and depends only on the look and its
/// context, so it is deterministic. When the count passes `Budget.steps`, the handler stops the script with an
/// error the look cannot catch, on the run's own thread, and the run returns. Memory is every byte the runtime
/// holds from the system allocator, built-ins included, and a request past `Budget.memory` is refused. A run
/// that met either cap fails with that cap's line, whatever the look did next. The script stack is capped too,
/// so deep recursion throws a `RangeError` the look can see, instead of crashing the process.
///
/// Thread: each run gets one thread with a fixed stack, and the thread ends with the run, because the step,
/// memory, and stack caps stop every script. A fixed stack keeps the stack cap the same wherever the caller
/// runs, and the waiting caller is suspended rather than blocking a thread of Swift's cooperative pool. Runs on
/// one sandbox are serialized, so one sandbox holds at most one runtime at a time.
///
/// `Budget` and `Failure` are nested because the actor shares its module's name, which would make
/// `Sandbox.Budget` unreachable as a module-qualified name.
package actor Sandbox {
    private var running = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    package init() {}

    package func run(_ source: String, context: String, budget: Budget) async throws(Failure) -> String {
        await acquire()
        defer { release() }
        let result = await withCheckedContinuation { continuation in
            let thread = Thread {
                continuation.resume(returning: Run.evaluate(source, context: context, budget: budget))
            }
            thread.name = "look"
            thread.stackSize = Run.threadStack
            thread.start()
        }
        return try result.get()
    }

    /// The actor is reentrant across `await`, so a second run would otherwise start while the first is still
    /// on its thread. Waiters run in arrival order, and `release` hands the slot straight to the next one.
    private func acquire() async {
        if running {
            await withCheckedContinuation { waiting.append($0) }
        } else {
            running = true
        }
    }

    private func release() {
        if waiting.isEmpty {
            running = false
        } else {
            waiting.removeFirst().resume()
        }
    }
}

extension Sandbox {
    package struct Budget: Sendable, Equatable {
        /// Interrupt-handler calls, each 10,000 interpreter checkpoints.
        package var steps: Int
        /// Bytes the runtime may hold at once, built-ins included. Whole megabytes, as the failure line says.
        package var memory: Int

        package init(steps: Int, memory: Int) {
            self.steps = steps
            self.memory = memory
        }

        /// What a widget render may use on device. Every reference look takes 1 step and under 0.3 MB; a step is
        /// 15 to 65 microseconds on an Apple M4, so an endless loop stops within 30 to 130 ms there.
        package static let widget = Budget(steps: 2000, memory: 12 << 20)
        /// Proofs are stricter, so a look that passes still fits when the real rows outgrow the samples.
        package static let proof = Budget(steps: 500, memory: 8 << 20)
    }

    package enum Failure: Error, Sendable, Equatable {
        case threw(message: String, line: Int?)
        case impure(String, line: Int?)
        case timedOut(steps: Int)
        case outOfMemory(bytes: Int)
        case missingRender
        case badReturn(String)

        /// The one line the builder sends the model, like `look threw TypeError: d.last is null (line 14)`.
        package var line: String {
            func at(_ line: Int?) -> String { line.map { " (line \($0))" } ?? "" }
            let text: String
            switch self {
            case .threw(let message, let line):
                text = "look threw \(message)\(at(line))"
            case .impure(let read, let line):
                text =
                    "look is not pure: \(read)\(at(line)); draw from ctx only (ctx.today has the date, and nothing may be random)"
            case .timedOut(let steps):
                text =
                    "look ran longer than \(steps) steps; render(ctx) must finish quickly, so look for an endless loop"
            case .outOfMemory(let bytes):
                text =
                    "look used more than \(bytes >> 20) MB of memory; render(ctx) must build a small tree, so look for a loop that keeps growing an array or string"
            case .missingRender:
                text = "look defines no function render(ctx); define it at the top level of the script"
            case .badReturn(let message):
                text = message
            }
            return text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).joined(separator: " ")
        }
    }
}

/// What one run has used. Only the run's thread touches it: the interrupt handler and the allocator.
private struct Meter {
    let budget: Sandbox.Budget
    var steps = 0
    var bytes = 0
    /// Set when the allocator turned a request down, which is how a run meets the memory cap.
    var refused = false

    var outOfSteps: Bool { steps > budget.steps }

    mutating func admit(_ more: Int) -> Bool {
        if bytes + more > budget.memory { refused = true }
        return bytes + more <= budget.memory
    }
}

/// One evaluation, entirely on the run's thread, in a runtime that lives exactly as long as the call.
private enum Run {
    /// The run thread's stack. The script stack cap sits well inside it, leaving the rest for C frames that
    /// QuickJS does not check and for this file.
    static let threadStack = 4 << 20
    static let scriptStack = 1 << 20

    static func evaluate(_ source: String, context json: String, budget: Sandbox.Budget) -> Result<
        String, Sandbox.Failure
    > {
        let meter = UnsafeMutablePointer<Meter>.allocate(capacity: 1)
        meter.initialize(to: Meter(budget: budget))
        defer {
            meter.deinitialize(count: 1)
            meter.deallocate()
        }
        guard let runtime = withUnsafePointer(to: allocator, { JS_NewRuntime2($0, meter) }) else {
            return .failure(.outOfMemory(bytes: budget.memory))
        }
        defer {
            JS_FreeRuntime(runtime)
            assert(meter.pointee.bytes == 0, "the QuickJS runtime leaked \(meter.pointee.bytes) bytes")
        }
        JS_SetMaxStackSize(runtime, scriptStack)
        JS_SetInterruptHandler(
            runtime,
            { _, opaque in
                guard let meter = metered(opaque) else { return 1 }
                meter.pointee.steps += 1
                return meter.pointee.outOfSteps ? 1 : 0
            }, meter)
        let result: Result<String, Sandbox.Failure>
        if let context = JS_NewContext(runtime) {
            result = Script(context: context).run(source, context: json)
            JS_FreeContext(context)
        } else {
            result = .failure(.threw(message: "the JavaScript engine did not start", line: nil))
        }
        // A cap outranks whatever the script made of meeting it: the stop is uncatchable but surfaces as an
        // exception, and a look may catch a refused allocation and carry on.
        if meter.pointee.outOfSteps { return .failure(.timedOut(steps: budget.steps)) }
        if meter.pointee.refused { return .failure(.outOfMemory(bytes: budget.memory)) }
        return result
    }

    /// The system allocator, counted against the memory budget. QuickJS carves small blocks out of arenas it
    /// allocates through these, so the count is what the runtime really holds. It is deterministic: the same
    /// look and context make the same requests, and `malloc_size` rounds a request the same way every time.
    /// `JS_SetMemoryLimit` is not used, because when its cap is hit QuickJS often cannot allocate the error
    /// either and throws `null`, which cannot be told apart from a look's own `throw null`.
    private static var allocator: JSMallocFunctions {
        JSMallocFunctions(
            js_calloc: { opaque, count, size in
                let (total, overflow) = count.multipliedReportingOverflow(by: size)
                guard !overflow, let meter = metered(opaque), meter.pointee.admit(total),
                    let pointer = calloc(count, size)
                else { return nil }
                meter.pointee.bytes += malloc_size(pointer)
                return pointer
            },
            js_malloc: { opaque, size in
                guard let meter = metered(opaque), meter.pointee.admit(size), let pointer = malloc(size) else {
                    return nil
                }
                meter.pointee.bytes += malloc_size(pointer)
                return pointer
            },
            js_free: { opaque, pointer in
                guard let pointer else { return }
                metered(opaque)?.pointee.bytes -= malloc_size(pointer)
                free(pointer)
            },
            js_realloc: { opaque, pointer, size in
                guard let meter = metered(opaque) else { return nil }
                let old = pointer.map { malloc_size($0) } ?? 0
                if size == 0 {
                    meter.pointee.bytes -= old
                    free(pointer)
                    return nil
                }
                guard meter.pointee.admit(size - old), let moved = realloc(pointer, size) else { return nil }
                meter.pointee.bytes += malloc_size(moved) - old
                return moved
            },
            js_malloc_usable_size: { pointer in malloc_size(pointer) })
    }
}

/// The meter behind the opaque pointer QuickJS hands back to the handler and the allocator. A free function,
/// because a C function pointer cannot capture the enum it would otherwise belong to.
private func metered(_ opaque: UnsafeMutableRawPointer?) -> UnsafeMutablePointer<Meter>? {
    opaque?.assumingMemoryBound(to: Meter.self)
}

/// The prelude, the look, and the entry call, in one context. Every `JSValue` here is freed on every path.
private struct Script {
    let context: OpaquePointer

    func run(_ source: String, context json: String) -> Result<String, Sandbox.Failure> {
        let entry = evaluate(Self.prelude, file: "prelude.js")
        defer { JS_FreeValue(context, entry) }
        guard !JS_IsException(entry) else { return .failure(failure(prefix: "the sandbox prelude failed: ")) }

        let look = evaluate(source, file: "look.js")
        JS_FreeValue(context, look)
        guard !JS_IsException(look) else { return .failure(failure()) }

        var argument = json.withCString { JS_NewStringLen(context, $0, json.utf8.count) }
        guard !JS_IsException(argument) else { return .failure(failure()) }
        // `undefined` as `this`, spelled out because `JS_UNDEFINED` is a C macro Swift cannot import. This is
        // QuickJS's 64-bit layout, the only one on iOS and macOS.
        let undefined = JSValue(u: JSValueUnion(uint64: 0), tag: Int64(JS_TAG_UNDEFINED))
        let tree = JS_Call(context, entry, undefined, 1, &argument)
        JS_FreeValue(context, argument)
        defer { JS_FreeValue(context, tree) }
        guard !JS_IsException(tree) else { return .failure(failure()) }
        guard JS_IsString(tree), let text = string(tree) else {
            return .failure(.badReturn("render(ctx) returned something that is not JSON"))
        }
        return .success(text)
    }

    private func evaluate(_ code: String, file: String) -> JSValue {
        code.withCString { JS_Eval(context, $0, code.utf8.count, file, JS_EVAL_TYPE_GLOBAL) }
    }

    /// Takes the pending exception and turns it into the failure for the model.
    private func failure(prefix: String = "") -> Sandbox.Failure {
        let exception = JS_GetException(context)
        defer { JS_FreeValue(context, exception) }
        let name = stringProperty(exception, "name")
        let message = stringProperty(exception, "message") ?? ""
        switch name {
        case "Impure" where prefix.isEmpty:
            return .impure(message, line: numberProperty(exception, "lookLine"))
        case "MissingRender" where prefix.isEmpty:
            return .missingRender
        case "BadTree" where prefix.isEmpty:
            return .badReturn(message)
        default:
            return .threw(
                message: prefix + (string(exception) ?? "an exception that cannot be shown"),
                line: prefix.isEmpty ? lookLine(of: exception) : nil)
        }
    }

    /// The look's own line: the first frame in look.js on the stack. A syntax error in look.js has that frame
    /// too, at the place the parser stopped.
    private func lookLine(of exception: JSValue) -> Int? {
        guard let stack = stringProperty(exception, "stack"), let range = stack.range(of: "look.js:") else {
            return nil
        }
        return Int(stack[range.upperBound...].prefix { $0.isASCII && $0.isNumber })
    }

    /// The value as text, or nil when the conversion threw. Converting can run script (a `toString` method),
    /// so that exception is taken and dropped here, and the step and memory caps still apply.
    private func string(_ value: JSValue) -> String? {
        var length = 0
        guard let bytes = JS_ToCStringLen2(context, &length, value, false) else {
            JS_FreeValue(context, JS_GetException(context))
            return nil
        }
        defer { JS_FreeCString(context, bytes) }
        return String(decoding: UnsafeRawBufferPointer(start: bytes, count: length), as: UTF8.self)
    }

    /// A property of an object, or nil when the value is not an object or reading the property threw.
    private func property(_ object: JSValue, _ name: String) -> JSValue? {
        guard JS_IsObject(object) else { return nil }
        let value = JS_GetPropertyStr(context, object, name)
        guard !JS_IsException(value) else {
            JS_FreeValue(context, JS_GetException(context))
            return nil
        }
        return value
    }

    private func stringProperty(_ object: JSValue, _ name: String) -> String? {
        guard let value = property(object, name) else { return nil }
        defer { JS_FreeValue(context, value) }
        return JS_IsString(value) ? string(value) : nil
    }

    private func numberProperty(_ object: JSValue, _ name: String) -> Int? {
        guard let value = property(object, name) else { return nil }
        defer { JS_FreeValue(context, value) }
        var number = 0.0
        guard JS_IsNumber(value), JS_ToFloat64(context, &number, value) == 0 else { return nil }
        return Int(exactly: number)
    }

    /// Evaluates to the entry function, which the look cannot reach: it calls `render` with the parsed
    /// context and returns the tree as JSON text. The walk keeps its own stack instead of recursing, so a
    /// tree at the depth limit needs no script stack.
    private static let prelude = #"""
        (function () {
          'use strict';
          var impurity = null;

          function lookLine(stack) {
            var match = /look\.js:(\d+)/.exec(String(stack || ''));
            return match ? Number(match[1]) : null;
          }

          function fail(name, message) {
            var error = new Error(message);
            error.name = name;
            return error;
          }

          function impure(read) {
            return function () {
              var error = fail('Impure', read);
              error.lookLine = lookLine(error.stack);
              if (impurity === null) impurity = error;
              throw error;
            };
          }

          Object.defineProperty(Math, 'random', { value: impure('Math.random() is random'), writable: false, configurable: false });

          var RealDate = Date;
          var readsClock = impure('Date() reads the clock');
          var PureDate = function Date() {
            if (!new.target || arguments.length === 0) return readsClock();
            return Reflect.construct(RealDate, Array.prototype.slice.call(arguments), new.target);
          };
          PureDate.prototype = RealDate.prototype;
          PureDate.UTC = RealDate.UTC;
          PureDate.parse = RealDate.parse;
          PureDate.now = impure('Date.now() reads the clock');
          Object.defineProperty(RealDate.prototype, 'constructor', { value: PureDate, writable: false, configurable: false });
          Object.defineProperty(globalThis, 'Date', { value: PureDate, writable: false, configurable: false });
          Object.defineProperty(globalThis, 'performance', {
            value: Object.freeze(Object.defineProperties({}, {
              now: { value: impure('performance.now() reads the clock') },
              timeOrigin: { get: impure('performance.timeOrigin reads the clock') }
            })),
            writable: false, configurable: false
          });
          delete globalThis.console;

          function walk(tree) {
            // Each entry holds its parent's path and its own step, joined only when the entry's turn comes.
            var pending = [[tree, '', 'root', 0]];
            while (pending.length > 0) {
              var next = pending.pop(), value = next[0], path = next[1] + next[2], depth = next[3];
              if (depth > 200) throw fail('BadTree', 'render(ctx) returned data nested more than 200 levels at ' + path + '; the tree must not contain itself');
              switch (typeof value) {
                case 'number':
                  if (!isFinite(value)) throw fail('BadTree', 'render(ctx) returned ' + value + ' at ' + path + '; numbers must be finite');
                  break;
                case 'function':
                  throw fail('BadTree', 'render(ctx) returned a function at ' + path + '; the tree must be plain data');
                case 'bigint':
                case 'symbol':
                  throw fail('BadTree', 'render(ctx) returned a ' + typeof value + ' at ' + path + '; the tree must be plain data');
                case 'object':
                  if (value === null) break;
                  if (Array.isArray(value)) {
                    for (var i = value.length - 1; i >= 0; i--) pending.push([value[i], path, '[' + i + ']', depth + 1]);
                  } else {
                    var keys = Object.keys(value);
                    for (var k = keys.length - 1; k >= 0; k--) pending.push([value[keys[k]], path, '.' + keys[k], depth + 1]);
                  }
                  break;
              }
            }
          }

          return function (contextJSON) {
            if (typeof render !== 'function') throw fail('MissingRender', 'no render');
            var tree = render(JSON.parse(contextJSON));
            if (impurity !== null) throw impurity;
            if (tree === undefined || tree === null) {
              throw fail('BadTree', 'render(ctx) returned ' + tree + '; it must return the root node object');
            }
            walk(tree);
            var text = JSON.stringify(tree);
            if (text.length > 1000000) throw fail('BadTree', 'render(ctx) returned ' + text.length + ' characters of JSON; draw far fewer nodes');
            return text;
          };
        })()
        """#
}
