import Foundation
import SwiftParser
import SwiftSyntax

// Spike: the front end the shell owns. Source text that is Swift's with the shell's in it goes in; Swift comes out, which a
// plain Swift front end reads. The loop: parse the text as Swift (with the insides of `$(…)` blanked), take the first place
// at or after the cursor where a form of the shell's may start, and read it; if it is one, replace it with the Swift it
// means, move the cursor past that, and parse again, so that everything before the cursor is Swift by the time anything
// after it is asked about.

final class Front {
    enum UnitKind { case pipeline, dollar }

    /// What the names the interpreter has are.
    let bound: Names
    /// Command lines whose words are all written out, for checking against the function they name before anything runs.
    struct CommandUse {
        var name: String
        var words: [String]
        var piped: Bool
        var source: String
    }
    private(set) var uses: [CommandUse] = []
    func record(use: CommandUse) { uses.append(use) }
    private(set) var units: [(kind: UnitKind, source: String)] = []

    /// How many parameters the closure given to a command takes, when the command is a function that says (nil: one).
    var closureArity: (String) -> Int? = { _ in nil }

    init(bound: Names) { self.bound = bound }

    func record(_ kind: UnitKind, _ source: String) { units.append((kind, source)) }

    struct StatementInfo {
        var isLabeled = false
        var isAssignment = false
        var isAsyncDeclaration = false
    }

    enum SiteKind {
        case statement(StatementInfo)
        case condition(isGuard: Bool)
        case substitution(underTry: Bool)
        case dollarName(underTry: Bool)
        case async(underTry: Bool)
        /// A shell's `'…'` in code, up to the character that ends it.
        case rawString(end: Int)

        var order: Int {
            switch self {
            case .statement: 0
            case .condition: 1
            case .substitution, .dollarName, .async, .rawString: 2
            }
        }
    }

    struct Site {
        var byte: Int
        var kind: SiteKind
    }

    /// Highlights what is not the shell's: Swift source (with the shell's blanked), as colored spans.
    var swiftHighlight: (String) -> [HighlightSpan] = { _ in [] }
    /// Whether a name is a method of what could flow into it and nothing a command could be by itself.
    var isMethodWithoutInput: (String) -> Bool = { _ in false }
    /// Reading goes on past a form that can't be read (a line half typed), keeping what was read of it.
    var recovering = false

    struct Cured {
        var text: String
        /// What the source is, for coloring it: the shell's forms and the Swift between them, in the source's characters.
        var spans: [HighlightSpan]
    }

    func cure(_ source: String, names inherited: Names? = nil, asExpression: Bool = false) throws -> String {
        try cureWithSpans(source, names: inherited, asExpression: asExpression).text
    }

    /// The program the source is, with every form of the shell's in it read.
    /// `asExpression`: the text is one expression (an argument, a closure, an interpolation), not a program: it is not read
    /// as a statement itself, only the forms inside it are.
    func cureWithSpans(_ source: String, names inherited: Names? = nil, asExpression: Bool = false) throws -> Cured {
        var chars = Array(source)
        var cursor = 0
        let base = inherited ?? bound
        var names = base
        /// How much longer the text is than the source, before the cursor.
        var delta = 0
        var spans: [HighlightSpan] = []
        var forms: [Range<Int>] = []
        func finish() -> Cured {
            // The Swift between the forms, read as Swift with the forms blanked.
            var blank = Array(source)
            for form in forms { for index in form where index < blank.count && blank[index] != "\n" { blank[index] = " " } }
            let swift = swiftHighlight(String(blank))
            return Cured(text: String(chars), spans: spans + swift)
        }
        for _ in 0...(chars.count + 1000) {
            let blanked = Text(Lex.blankingSubstitutions(chars))
            let text = Text(chars)
            let tree = Parser.parse(source: blanked.string)
            names = base.adding(declaredIn: tree)
            let cursorByte = text.byteOf[min(cursor, text.count)]
            var found: (start: Int, end: Int, replacement: String)?
            let content = chars.firstIndex { !$0.isWhitespace }.map { text.byteOf[$0] } ?? 0
            let raws = Lex.rawStrings(in: chars).map { Site(byte: text.byteOf[$0.lowerBound], kind: .rawString(end: $0.upperBound)) }
            var retry = false
            for site in (sites(in: tree) + raws).sorted(by: { ($0.byte, $0.kind.order) < ($1.byte, $1.kind.order) }) where site.byte >= cursorByte {
                if asExpression, site.byte == content, site.kind.order < 2 { continue }
                let start = text.character(atByte: site.byte)
                var read: (end: Int, replacement: String, spans: [HighlightSpan])?
                var partial: (end: Int, spans: [HighlightSpan]) = (start, [])
                do {
                    read = try self.read(site, at: start, text: text, blanked: blanked, names: names, partial: &partial)
                } catch is Failure where recovering {
                    // What was read of it before the problem is colored, and the rest is Swift's.
                    spans += partial.spans.map { HighlightSpan(range: ($0.range.lowerBound - delta)..<($0.range.upperBound - delta), kind: $0.kind) }
                    let stopped = min(max(partial.end, start + 1), chars.count)
                    forms.append((start - delta)..<(stopped - delta))
                    // On, past what could not be read.
                    cursor = stopped
                    retry = true
                    break
                }
                if let read {
                    found = (start, read.end, read.replacement)
                    spans += read.spans.map { HighlightSpan(range: ($0.range.lowerBound - delta)..<($0.range.upperBound - delta), kind: $0.kind) }
                    forms.append((start - delta)..<(read.end - delta))
                    break
                }
            }
            if retry { continue }
            guard var found else { return finish() }
            // The spaces after a form belong to what follows it.
            while found.end > found.start + 1, chars[found.end - 1] == " " || chars[found.end - 1] == "\t" { found.end -= 1 }
            chars.replaceSubrange(found.start..<found.end, with: Array(found.replacement))
            delta += found.replacement.count - (found.end - found.start)
            cursor = found.start + found.replacement.count
        }
        throw Failure("the front end did not settle")
    }

    private func read(_ site: Site, at start: Int, text: Text, blanked: Text, names: Names, partial: inout (end: Int, spans: [HighlightSpan])) throws -> (end: Int, replacement: String, spans: [HighlightSpan])? {
        var reader = Reader(front: self, text: text, blanked: blanked, names: names, at: start)
        defer { partial = (reader.pos, reader.spans) }
        func isStarting(_ info: StatementInfo?) -> Bool {
            // `$0` is a closure's parameter, found where Swift reads one.
            if reader.peek() == "$", let next = reader.peek(1), Lex.isDigit(next) { return false }
            let word = reader.identifier()
            if let word, word != "try", Reader.statementKeywords.union(["if", "for", "while", "switch", "let", "var"]).contains(word) { return false }
            if let info {
                if info.isLabeled { return false }
                if word == "_", info.isAssignment { return false }
                if word == "async", info.isAsyncDeclaration { return false }
                if let word, [.variable, .member, .type, .staticMember].contains(names.role(of: word, at: reader.here)), info.isAssignment { return false }
            }
            return true
        }
        switch site.kind {
        case .statement(let info):
            guard isStarting(info), let chain = try reader.parseCommandChain(condition: false) else { return nil }
            return (reader.pos, reader.emit(chain, statement: true), reader.spans)
        case .condition(let isGuard):
            reader.conditionDepth = 1
            reader.guardCondition = isGuard
            guard isStarting(nil), let chain = try reader.parseCommandChain(condition: true) else { return nil }
            return (reader.pos, reader.emit(chain, statement: false), reader.spans)
        case .substitution(let underTry), .dollarName(let underTry):
            reader.tryDepth = underTry ? 1 : 0
            guard let expression = try reader.parseShellDollar() else { return nil }
            return (reader.pos, expression, reader.spans)
        case .rawString(let end):
            let content = text.slice((start + 1)..<max(start + 1, end - 1))
            var hashes = "#"
            while content.contains("\"" + hashes) { hashes += "#" }
            return (end, hashes + "\"" + content + "\"" + hashes, [HighlightSpan(range: start..<end, kind: .string)])
        case .async(let underTry):
            reader.tryDepth = underTry ? 1 : 0
            let expression = try reader.parseAsync()
            return (reader.pos, expression, reader.spans)
        }
    }

    // MARK: Where a form may start

    private func sites(in tree: SourceFileSyntax) -> [Site] {
        let finder = SiteFinder(viewMode: .sourceAccurate)
        finder.walk(tree)
        return finder.sites
    }
}

private final class SiteFinder: SyntaxVisitor {
    var sites: [Front.Site] = []

    override func visit(_ node: CodeBlockItemSyntax) -> SyntaxVisitorContinueKind {
        var info = Front.StatementInfo()
        switch node.item {
        case .stmt(let stmt): info.isLabeled = stmt.is(LabeledStmtSyntax.self)
        case .expr(let expr): info.isAssignment = SiteFinder.isAssignment(expr)
        case .decl(let decl):
            info.isAsyncDeclaration = decl.is(VariableDeclSyntax.self)
        }
        sites.append(Front.Site(byte: node.positionAfterSkippingLeadingTrivia.utf8Offset, kind: .statement(info)))
        return .visitChildren
    }

    override func visit(_ token: TokenSyntax) -> SyntaxVisitorContinueKind {
        guard token.presence == .present else { return .skipChildren }
        let byte = token.positionAfterSkippingLeadingTrivia.utf8Offset
        switch token.tokenKind {
        case .keyword(.if), .keyword(.while), .keyword(.guard):
            // The statement's keyword, not a label that is spelled like one (`prefix(while: …)`).
            let owner = token.parent
            guard owner?.is(IfExprSyntax.self) == true || owner?.is(WhileStmtSyntax.self) == true || owner?.is(GuardStmtSyntax.self) == true
                    || owner?.is(RepeatStmtSyntax.self) == true else { break }
            if let next = token.nextToken(viewMode: .sourceAccurate) {
                sites.append(Front.Site(byte: next.positionAfterSkippingLeadingTrivia.utf8Offset, kind: .condition(isGuard: token.tokenKind == .keyword(.guard))))
            }
        case .dollarIdentifier:
            let text = token.text
            if text == "$" {
                if let next = token.nextToken(viewMode: .sourceAccurate), next.tokenKind == .leftParen, next.positionAfterSkippingLeadingTrivia == token.endPositionBeforeTrailingTrivia {
                    sites.append(Front.Site(byte: byte, kind: .substitution(underTry: SiteFinder.underTry(token))))
                }
            }
        case .identifier(let text):
            if text == "async" {
                if token.parent?.is(DeclReferenceExprSyntax.self) == true {
                    sites.append(Front.Site(byte: byte, kind: .async(underTry: SiteFinder.underTry(token))))
                }
            } else if text.hasPrefix("$"), text.count > 1, Int(text.dropFirst()) == nil {
                sites.append(Front.Site(byte: byte, kind: .dollarName(underTry: SiteFinder.underTry(token))))
            }
        default: break
        }
        return .skipChildren
    }

    /// Whether a `try` covers the token, without a closure or function between.
    static func underTry(_ token: TokenSyntax) -> Bool {
        var node = token.parent
        while let current = node {
            if current.is(TryExprSyntax.self) { return true }
            if current.is(ClosureExprSyntax.self) || current.is(FunctionDeclSyntax.self) || current.is(InitializerDeclSyntax.self) || current.is(AccessorDeclSyntax.self) { return false }
            node = current.parent
        }
        return false
    }

    static func isAssignment(_ expr: ExprSyntax) -> Bool {
        guard let infix = expr.as(InfixOperatorExprSyntax.self) else {
            // Unfolded: a sequence with an assignment operator in it.
            if let sequence = expr.as(SequenceExprSyntax.self) {
                return sequence.elements.contains { element in
                    if element.is(AssignmentExprSyntax.self) { return true }
                    if let op = element.as(BinaryOperatorExprSyntax.self)?.operator.text { return ["+=", "-=", "*=", "/=", "%=", "??="].contains(op) }
                    return false
                }
            }
            return false
        }
        if infix.operator.is(AssignmentExprSyntax.self) { return true }
        return false
    }
}
