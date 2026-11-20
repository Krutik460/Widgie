import Foundation
import JavaScriptCore

struct JSRun {
    var tree: JSON
    var setupMs: Double
    var evalMs: Double
}

final class JSBox: @unchecked Sendable {
    var result: Result<JSON, LookError>?
    var setupMs = 0.0
    var evalMs = 0.0
}

let jsSerializer = """
(function (ctxJson) {
  if (typeof render !== 'function') throw new Error('the script must define function render(ctx)');
  var tree = render(JSON.parse(ctxJson));
  if (tree === undefined || tree === null) throw new Error('render(ctx) returned ' + tree + '; it must return a node object');
  return JSON.stringify(tree, function (k, v) {
    if (typeof v === 'number' && !isFinite(v)) throw new Error('prop "' + k + '" is ' + v + '; numbers must be finite');
    if (typeof v === 'function') throw new Error('prop "' + k + '" is a function; the tree must be plain data');
    if (k === 'children' && Array.isArray(v)) {
      return v.flat(Infinity).filter(function (c) { return c !== null && c !== undefined && c !== false; });
    }
    return v;
  });
})
"""

func nowMs() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e6 }

func evaluateJS(source: String, ctxJson: String, box: JSBox) {
    let t0 = nowMs()
    guard let context = JSContext() else {
        box.result = .failure(LookError("could not create a JSContext"))
        return
    }
    var thrown: String?
    context.exceptionHandler = { _, exc in
        guard let exc else { return }
        var msg = exc.toString() ?? "unknown error"
        if let url = exc.objectForKeyedSubscript("sourceURL"), url.isString, url.toString() == "look.js",
           let line = exc.objectForKeyedSubscript("line"), line.isNumber { msg += " (line \(line.toInt32()))" }
        thrown = msg
    }
    let serializer = context.evaluateScript(jsSerializer)
    let t1 = nowMs()
    box.setupMs = t1 - t0

    context.evaluateScript(source, withSourceURL: URL(string: "look.js")!)
    if let thrown {
        box.evalMs = nowMs() - t1
        box.result = .failure(LookError("JS exception while loading the script: \(thrown)"))
        return
    }
    let out = serializer?.call(withArguments: [ctxJson])
    box.evalMs = nowMs() - t1
    if let thrown {
        box.result = .failure(LookError("JS exception: \(thrown)"))
        return
    }
    guard let out, out.isString, let s = out.toString(), let data = s.data(using: .utf8) else {
        box.result = .failure(LookError("render(ctx) must return a node object"))
        return
    }
    do {
        box.result = .success(try JSON.parse(data, what: "the tree returned by render(ctx)"))
    } catch let e as LookError {
        box.result = .failure(e)
    } catch {
        box.result = .failure(LookError("\(error)"))
    }
}

func runJS(source: String, ctxJson: String, limitMs: Int) throws -> JSRun {
    let box = JSBox()
    let done = DispatchSemaphore(value: 0)
    let thread = Thread {
        evaluateJS(source: source, ctxJson: ctxJson, box: box)
        done.signal()
    }
    thread.stackSize = 8 << 20
    thread.start()
    // JavaScriptCore has no public API to interrupt a running script, so the limit is enforced by
    // abandoning the thread. The caller exits the process on this error.
    if done.wait(timeout: .now() + .milliseconds(limitMs + 500)) == .timedOut {
        throw LookError("JS ran longer than \(limitMs) ms; render(ctx) must finish quickly (check for an infinite loop)")
    }
    if box.evalMs > Double(limitMs) {
        throw LookError("JS ran longer than \(limitMs) ms (\(Int(box.evalMs)) ms); render(ctx) must finish quickly")
    }
    switch box.result! {
    case .success(let tree): return JSRun(tree: tree, setupMs: box.setupMs, evalMs: box.evalMs)
    case .failure(let e): throw e
    }
}
