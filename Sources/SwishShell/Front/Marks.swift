import Foundation
import SwiftParser
import SwiftSyntax

// What a script's functions say about their parameters that Swift's declaration can't: `@input` takes what is piped in,
// `@flag("n")` gives an option a short name. These are the shell's, so the front end reads them and leaves Swift without them.

extension Shell {
    /// The source with those marks blanked (the same length, so every position stands), and what they said, by `function.parameter`.
    func removingMarks(from swift: String) -> (source: String, marks: [String: CommandMarks.Marks]) {
        guard swift.contains("@input") || swift.contains("@flag") else { return (swift, [:]) }
        let finder = MarkFinder(viewMode: .sourceAccurate)
        finder.walk(Parser.parse(source: swift))
        guard !finder.blanks.isEmpty else { return (swift, [:]) }
        var bytes = Array(swift.utf8)
        for range in finder.blanks { for index in range where bytes.indices.contains(index) { bytes[index] = UInt8(ascii: " ") } }
        return (String(decoding: bytes, as: UTF8.self), finder.marks)
    }
}

private final class MarkFinder: SyntaxVisitor {
    var marks: [String: CommandMarks.Marks] = [:]
    var blanks: [Range<Int>] = []

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        let function = node.name.text
        for parameter in node.signature.parameterClause.parameters {
            let name = (parameter.secondName ?? parameter.firstName).text
            for element in parameter.attributes {
                guard case .attribute(let attribute) = element else { continue }
                let kind = attribute.attributeName.trimmedDescription.lowercased()
                guard kind == "input" || kind == "flag" else { continue }
                var found = marks["\(function).\(name)"] ?? CommandMarks.Marks()
                if kind == "input" { found.isInput = true }
                if kind == "flag", case .argumentList(let arguments)? = attribute.arguments,
                   let literal = arguments.first?.expression.as(StringLiteralExprSyntax.self)?.representedLiteralValue?.first {
                    found.shortFlag = literal
                } else if kind == "flag" {
                    found.shortFlag = name.first
                }
                marks["\(function).\(name)"] = found
                blanks.append(attribute.positionAfterSkippingLeadingTrivia.utf8Offset..<attribute.endPositionBeforeTrailingTrivia.utf8Offset)
            }
        }
        return .visitChildren
    }
}
