import SwiftParser
import SwiftSyntax

// `await job` is the shell's: Swift's `await` goes on an `async` call, and a job is a value that is
// waited for by a blocking call, anywhere. So the front end writes it as `await waited(job)`, which the
// prelude declares for a job (what it gave, by the type it was started with) and for anything else (the
// value itself, which is what an `async let` or a task's `value` is once it is awaited). A bare `await`
// waits for the latest job. An `await` of a call is Swift's own and is left alone.

extension Front {
    /// `text` with every `await` that is not on a call written as a call of `awaited`.
    static func desugaringAwaits(_ text: String) -> String {
        guard text.contains("await") else { return text }
        var current = text
        // A pass rewrites the outermost; what was inside one is read on the next.
        for _ in 0..<8 {
            let rewrites = AwaitFinder.find(in: current)
            guard !rewrites.isEmpty else { return current }
            var bytes = Array(current.utf8)
            for rewrite in rewrites.sorted(by: { $0.start > $1.start }) {
                bytes.replaceSubrange(rewrite.start..<rewrite.end, with: Array(rewrite.text.utf8))
            }
            current = String(decoding: bytes, as: UTF8.self)
        }
        return current
    }
}

/// A stretch of source to replace, by byte: where `await` is made explicit.

private struct AwaitRewrite {
    var start: Int
    var end: Int
    var text: String
}

/// Finds the calls that need an `await` written in front of them.

private final class AwaitFinder: SyntaxVisitor {
    var rewrites: [AwaitRewrite] = []
    var source = ""

    static func find(in text: String) -> [AwaitRewrite] {
        let finder = AwaitFinder(viewMode: .sourceAccurate)
        finder.source = text
        finder.walk(Parser.parse(source: text))
        return finder.rewrites
    }

    override func visit(_ node: AwaitExprSyntax) -> SyntaxVisitorContinueKind {
        let throwing = AwaitFinder.underTry(node)
        let name = throwing ? "waitedFailing" : "waited"
        let operand = node.expression
        if operand.is(MissingExprSyntax.self) {
            // A bare `await`.
            let at = node.awaitKeyword.endPositionBeforeTrailingTrivia.utf8Offset
            rewrites.append(AwaitRewrite(start: at, end: at, text: " \(name)(latestJob())"))
            return .skipChildren
        }
        if AwaitFinder.isCall(operand) { return .visitChildren }
        let start = operand.positionAfterSkippingLeadingTrivia.utf8Offset
        let end = operand.endPositionBeforeTrailingTrivia.utf8Offset
        let bytes = Array(source.utf8)
        let written = String(decoding: bytes[start..<end], as: UTF8.self)
        rewrites.append(AwaitRewrite(start: start, end: end, text: "\(name)(\(written))"))
        // What is inside is read on the next pass.
        return .skipChildren
    }

    static func isCall(_ expr: ExprSyntax) -> Bool {
        var current = expr
        while let paren = current.as(TupleExprSyntax.self), paren.elements.count == 1,
            let inner = paren.elements.first?.expression
        {
            current = inner
        }
        return current.is(FunctionCallExprSyntax.self)
    }

    /// Whether a `try` covers the node, without a closure or function between.
    static func underTry(_ node: some SyntaxProtocol) -> Bool {
        var parent = node.parent
        while let current = parent {
            if current.is(TryExprSyntax.self) { return true }
            if current.is(ClosureExprSyntax.self) || current.is(FunctionDeclSyntax.self)
                || current.is(InitializerDeclSyntax.self) || current.is(AccessorDeclSyntax.self)
            {
                return false
            }
            parent = current.parent
        }
        return false
    }
}
