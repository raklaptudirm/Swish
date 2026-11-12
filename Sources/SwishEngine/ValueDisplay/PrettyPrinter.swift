import Foundation
import Swiit

/// Shows a value as `debugDescription` spells it, but for a person: in the
/// highlighter's colors, and, when it won't fit on one line, broken over
/// lines with each element or field on its own, the way you'd format it as
/// Swift. A string of several lines is a `"""` literal then.
struct PrettyPrinter: Sendable {
    var width = 80
    var styled = false

    init(width: Int = 80, styled: Bool = false) {
        self.width = width
        self.styled = styled
    }

    /// A value's shape: text that can't be broken, a string, or brackets
    /// around (labeled) elements.
    indirect enum Node {
        case segments([Segment])
        case string(String)
        case group(open: [Segment], items: [(label: [Segment], node: Node)], close: String)
    }

    func format(_ value: Value) -> String {
        render(node(for: value), indent: 0, used: 0, trailing: 0)
    }

    // MARK: Shapes

    func node(for value: Value) -> Node {
        switch value.kind {
        case .nothing: return .segments([Segment("nil", .constant)])
        case .bool, .int, .double: return .segments([Segment(value.description, .constant)])
        case .function: return .segments([Segment(value.description)])
        case .string: return .string(value.description)

        case .list:
            let items = value.casting(to: [Value].self) ?? []
            return .group(
                open: [Segment("[")],
                items: items.map { ([], node(for: $0)) },
                close: "]"
            )

        case .structure, .tuple:
            return value.fields.map { node(for: $0) }
                ?? .segments([Segment(value.debugDescription)])

        case .dictionary:
            let dictionary = value.entries ?? []
            return dictionary.isEmpty
                ? .segments([Segment("[:]")])
                : .group(
                    open: [Segment("[")],
                    items: dictionary.sortedForDisplay.map { key, value in
                        ([keySegment(key), Segment(": ")], node(for: value))
                    },
                    close: "]"
                )

        case .enumeration:
            return value.enumCaseName.map { node(forCase: $0, of: value) }
                ?? .segments([Segment(value.debugDescription)])

        case .object:
            // A command's output is laid out as the struct it is; any other Swift value as its type
            // says it looks, in a style.
            if let output = value.commandOutput { return node(for: output.displayValue) }
            if let role = value.displayShape.role {
                return .segments([Segment(value.description, role)])
            }
            if let segments = value.casting(toExistential: (any Presentable).self)?.styledSegments {
                return .segments(segments)
            }
            // A type, not data: it shows as `enum Name`.
            if value.description.hasPrefix("enum ") {
                return .segments([
                    Segment("enum", .keyword), Segment(" "),
                    Segment(String(value.description.dropFirst(5)), .type),
                ])
            }
            return value.fields.map { node(for: $0) }
                ?? .segments([Segment(value.debugDescription)])
        }
    }

    /// A struct's value, `Point(x: 1)`, or a tuple, `(name: "x", 2)`.
    private func node(for record: Fields) -> Node {
        let open: [Segment] =
            record.typeName.map { [Segment($0, .type), Segment("(")] } ?? [Segment("(")]
        return .group(
            open: open,
            items: record.map { field in
                (Fields.isPosition(field.key) ? [] : label(field.key), node(for: field.value))
            },
            close: ")"
        )
    }

    private func keySegment(_ key: Value) -> Segment {
        if key.kind == .string { return Segment(key.debugDescription, .string) }
        return Segment(key.debugDescription, .constant)
    }

    private func node(forCase name: String, of enumValue: Value) -> Node {
        let head: [Segment] = [
            Segment(enumValue.typeID?.name ?? "", .type), Segment("." + name),
        ]
        let payload = enumValue.enumPayload
        guard !payload.isEmpty else { return .segments(head) }
        let items = payload.map { field in
            (Fields.isPosition(field.key) ? [] : label(field.key), node(for: field.value))
        }
        return .group(open: head + [Segment("(")], items: items, close: ")")
    }

    private func label(_ name: String) -> [Segment] {
        [Segment(name + ": ")]
    }

    // MARK: Layout

    /// `node` starting `used` columns into a line indented by `indent`, with
    /// `trailing` columns (a comma) to follow it.
    private func render(_ node: Node, indent: Int, used: Int, trailing: Int) -> String {
        let line = flat(node)
        if !mustBreak(node, indent: indent), used + line.plain.count + trailing <= width {
            return line.styled
        }

        switch node {
        case .segments:
            return line.styled  // Can't be broken.

        case .string(let text):
            guard text.contains("\n") else { return line.styled }
            let inner = String(repeating: " ", count: indent + 2)
            let body = text.split(separator: "\n", omittingEmptySubsequences: false)
                .map { row in
                    row.isEmpty
                        ? ""
                        : inner
                            + PrettyPrinter.escapedForBlock(String(row))
                            .styled(DisplayStyle.string, styled)
                }
            let quotes = "\"\"\"".styled(DisplayStyle.string, styled)
            return quotes + "\n" + body.joined(separator: "\n") + "\n" + inner + quotes

        case .group(let open, let items, let close):
            guard !items.isEmpty else { return line.styled }
            let inner = String(repeating: " ", count: indent + 2)
            let rows = items.enumerated()
                .map { index, item in
                    let isLast = index == items.count - 1
                    let label = paint(item.label)
                    return inner + label.styled
                        + render(
                            item.node,
                            indent: indent + 2,
                            used: indent + 2 + label.plain.count,
                            trailing: isLast ? 0 : 1
                        )
                        + (isLast ? "" : ",")
                }
            return paint(open).styled + "\n" + rows.joined(separator: "\n") + "\n"
                + String(repeating: " ", count: indent) + close
        }
    }

    /// A string of several lines inside something is a `"""` block, so
    /// command output reads as it printed; what holds one breaks for it.
    private func mustBreak(_ node: Node, indent: Int) -> Bool {
        switch node {
        case .segments: false
        case .string(let text): indent > 0 && text.contains("\n")
        case .group(_, let items, _): items.contains { mustBreak($0.node, indent: 1) }
        }
    }

    /// The one-line form: exactly `debugDescription`, when plain.
    private func flat(_ node: Node) -> (plain: String, styled: String) {
        switch node {
        case .segments(let segments):
            return paint(segments)
        case .string(let text):
            let quoted = Value(text).debugDescription
            return (quoted, quoted.styled(DisplayStyle.string, styled))
        case .group(let open, let items, let close):
            var plain = paint(open).plain
            var colored = paint(open).styled
            for (index, item) in items.enumerated() {
                if index > 0 {
                    plain += ", "
                    colored += ", "
                }
                let label = paint(item.label)
                let value = flat(item.node)
                plain += label.plain + value.plain
                colored += label.styled + value.styled
            }
            return (plain + close, colored + close)
        }
    }

    /// A line of a `"""` literal: backslashes and control characters (an
    /// escape sequence in a program's output, say) escaped, so it can't be
    /// mistaken for anything else or change the terminal.
    static func escapedForBlock(_ line: String) -> String {
        var result = ""
        for scalar in line.unicodeScalars {
            switch scalar {
            case "\\": result += "\\\\"
            case "\t": result += "\t"
            case _ where scalar.value < 0x20 || scalar.value == 0x7F:
                result += "\\u{" + String(scalar.value, radix: 16, uppercase: true) + "}"
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result.replacingOccurrences(of: "\"\"\"", with: "\\\"\"\"")
    }

    private func paint(_ segments: [Segment]) -> (plain: String, styled: String) {
        (segments.map(\.text).joined(), segments.map { $0.text.styled($0.style, styled) }.joined())
    }
}
