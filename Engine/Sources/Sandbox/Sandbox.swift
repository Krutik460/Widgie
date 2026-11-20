import Foundation
import JavaScriptCore

/// The JavaScript engine boundary. Strings in, string out: the look source, the context as JSON text, and the
/// tree as JSON text. Both candidate engines (JavaScriptCore, or an embedded engine with step and memory
/// limits) fit this signature, so the device bakeoff replaces this file and nothing else. It is a concrete
/// type, not a protocol, because only one engine ships.
///
/// Per run: a fresh context in this sandbox's VM, so no state survives between renders. Runs are serialized,
/// because a VM runs one script at a time. Before the look loads, a prelude replaces `Math.random`,
/// `Date.now`, `Date()`, and argument-less `new Date()` with functions that record the read and throw, so
/// impurity fails every proof instead of flickering, even when the look catches the error. The tree is
/// serialized inside the engine with `JSON.stringify` after a walk that rejects what JSON cannot carry:
/// functions, non-finite numbers, and a tree that contains itself. The sandbox knows nothing about the node
/// vocabulary; flattening `children` and every other rule of the tree belong to the validator.
///
/// Budget: JavaScriptCore cannot interrupt a script, so a run happens on a dedicated thread and a timeout
/// abandons that thread and this VM; the next run starts a new VM. The abandoned thread spins until the
/// process exits. The clock starts when the look's source starts to evaluate, so VM and context setup do not
/// count against it. An embedded engine stops the script at the step limit instead. The builder rejects any
/// look that exceeds `Budget.proof`, and what a shipped widget does about a look that runs away waits on the
/// engine choice.
///
/// `Budget` and `Failure` are nested because the actor shares its module's name, which would make
/// `Sandbox.Budget` unreachable as a module-qualified name.
package actor Sandbox {
    private var machine: Machine?
    private var running = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    package init() {}

    package func run(_ source: String, context: String, budget: Budget) async throws(Failure) -> String {
        await acquire()
        defer { release() }
        let machine = self.machine ?? Machine()
        self.machine = machine
        let result = await Self.execute(source, context: context, on: machine, budget: budget.time)
        if case .failure(.timedOut) = result { self.machine = nil }
        return try result.get()
    }

    /// The actor is reentrant across `await`, so a second run would otherwise reach the VM while the first is
    /// still on it. Waiters run in arrival order, and `release` hands the slot straight to the next one.
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

    private static func execute(_ source: String, context: String, on machine: Machine, budget: Duration) async
        -> Result<String, Failure>
    {
        await withCheckedContinuation { continuation in
            let outcome = Outcome(continuation)
            let thread = Thread {
                let result = Run(machine: machine).evaluate(source, context: context) {
                    DispatchQueue.global().asyncAfter(deadline: .now() + budget.dispatchInterval) {
                        outcome.finish(.failure(.timedOut(budget)))
                    }
                }
                outcome.finish(result)
            }
            thread.name = "look"
            thread.stackSize = 4 << 20
            thread.start()
        }
    }
}

extension Sandbox {
    package struct Budget: Sendable {
        package var time: Duration
        package init(time: Duration) { self.time = time }
        /// What a widget render may take on device.
        package static let widget = Budget(time: .milliseconds(250))
        /// Proofs are stricter, so a look that passes has headroom on a slower phone.
        package static let proof = Budget(time: .milliseconds(100))
    }

    package enum Failure: Error, Sendable, Equatable {
        case threw(message: String, line: Int?)
        case impure(String, line: Int?)
        case timedOut(Duration)
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
            case .timedOut(let budget):
                let milliseconds =
                    budget.components.seconds * 1000 + budget.components.attoseconds / 1_000_000_000_000_000
                text =
                    "look ran longer than \(milliseconds) ms; render(ctx) must finish quickly, so look for an endless loop"
            case .missingRender:
                text = "look defines no function render(ctx); define it at the top level of the script"
            case .badReturn(let message):
                text = message
            }
            return text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).joined(separator: " ")
        }
    }
}

/// A VM, held by the sandbox and lent to one run thread at a time. JavaScriptCore locks a VM while a script
/// runs; the sandbox never lends one VM to two threads at once, and a VM whose thread was abandoned is
/// dropped, never lent again.
private final class Machine: @unchecked Sendable {
    let vm = JSVirtualMachine()
}

/// Resumes the waiting run exactly once: with the thread's result, or with the watchdog's timeout,
/// whichever comes first.
private final class Outcome: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Result<String, Sandbox.Failure>, Never>?

    init(_ continuation: CheckedContinuation<Result<String, Sandbox.Failure>, Never>) {
        self.continuation = continuation
    }

    func finish(_ result: Result<String, Sandbox.Failure>) {
        let waiting = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        waiting?.resume(returning: result)
    }
}

/// One evaluation, entirely on the run thread.
private struct Run {
    let machine: Machine

    private static let lookURL = URL(string: "look.js")
    private static let preludeURL = URL(string: "prelude.js")

    func evaluate(_ source: String, context json: String, startClock: () -> Void) -> Result<String, Sandbox.Failure> {
        guard let vm = machine.vm, let context = JSContext(virtualMachine: vm) else {
            return .failure(.threw(message: "the JavaScript engine did not start", line: nil))
        }
        var exception: JSValue?
        context.exceptionHandler = { _, value in exception = value }
        let entry = context.evaluateScript(Self.prelude, withSourceURL: Self.preludeURL)
        guard exception == nil, let entry, entry.isObject else {
            return .failure(.threw(message: "the sandbox prelude failed: \(Self.message(of: exception))", line: nil))
        }
        startClock()
        context.evaluateScript(source, withSourceURL: Self.lookURL)
        if let exception { return .failure(Self.failure(from: exception)) }
        let tree = entry.call(withArguments: [json])
        if let exception { return .failure(Self.failure(from: exception)) }
        guard let tree, tree.isString, let text = tree.toString() else {
            return .failure(.badReturn("render(ctx) returned something that is not JSON"))
        }
        return .success(text)
    }

    private static func failure(from exception: JSValue) -> Sandbox.Failure {
        let name = exception.isObject ? exception.forProperty("name")?.toString() : nil
        let message = exception.isObject ? exception.forProperty("message")?.toString() ?? "" : ""
        switch name {
        case "Impure":
            let line = exception.forProperty("lookLine").flatMap { $0.isNumber ? Int($0.toInt32()) : nil }
            return .impure(message, line: line)
        case "MissingRender":
            return .missingRender
        case "BadTree":
            return .badReturn(message)
        default:
            return .threw(message: Self.message(of: exception), line: lookLine(of: exception))
        }
    }

    private static func message(of exception: JSValue?) -> String {
        guard let exception else { return "unknown error" }
        return exception.toString() ?? "unknown error"
    }

    /// The look's own line: the first frame in look.js on the stack, or the error's line when the error is a
    /// syntax error in look.js, which has no stack.
    private static func lookLine(of exception: JSValue) -> Int? {
        guard exception.isObject else { return nil }
        if let stack = exception.forProperty("stack")?.toString(), let line = firstLookLine(in: stack) {
            return line
        }
        if exception.forProperty("sourceURL")?.toString() == "look.js",
            let line = exception.forProperty("line"), line.isNumber
        {
            return Int(line.toInt32())
        }
        return nil
    }

    private static func firstLookLine(in stack: String) -> Int? {
        guard let range = stack.range(of: "look.js:") else { return nil }
        return Int(stack[range.upperBound...].prefix { $0.isASCII && $0.isNumber })
    }

    /// Evaluates to the entry function, which the look cannot reach: it calls `render` with the parsed
    /// context and returns the tree as JSON text.
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
          delete globalThis.console;

          function walk(value, path, depth) {
            if (depth > 200) throw fail('BadTree', 'render(ctx) returned data nested more than 200 levels at ' + path + '; the tree must not contain itself');
            switch (typeof value) {
              case 'number':
                if (!isFinite(value)) throw fail('BadTree', 'render(ctx) returned ' + value + ' at ' + path + '; numbers must be finite');
                return;
              case 'function':
                throw fail('BadTree', 'render(ctx) returned a function at ' + path + '; the tree must be plain data');
              case 'bigint':
              case 'symbol':
                throw fail('BadTree', 'render(ctx) returned a ' + typeof value + ' at ' + path + '; the tree must be plain data');
              case 'object':
                if (value === null) return;
                if (Array.isArray(value)) {
                  for (var i = 0; i < value.length; i++) walk(value[i], path + '[' + i + ']', depth + 1);
                } else {
                  var keys = Object.keys(value);
                  for (var k = 0; k < keys.length; k++) walk(value[keys[k]], path + '.' + keys[k], depth + 1);
                }
                return;
            }
          }

          return function (contextJSON) {
            if (typeof render !== 'function') throw fail('MissingRender', 'no render');
            var tree = render(JSON.parse(contextJSON));
            if (impurity !== null) throw impurity;
            if (tree === undefined || tree === null) {
              throw fail('BadTree', 'render(ctx) returned ' + tree + '; it must return the root node object');
            }
            walk(tree, 'root', 0);
            var text = JSON.stringify(tree);
            if (text.length > 1000000) throw fail('BadTree', 'render(ctx) returned ' + text.length + ' characters of JSON; draw far fewer nodes');
            return text;
          };
        })()
        """#
}

extension Duration {
    fileprivate var dispatchInterval: DispatchTimeInterval {
        .nanoseconds(Int(components.seconds) * 1_000_000_000 + Int(components.attoseconds / 1_000_000_000))
    }
}
