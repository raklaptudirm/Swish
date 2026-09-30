// Reads a Swift module's symbol graph and writes the Swift that bridges
// its types' members to Swish: each member's signature, for the checker,
// and glue that converts Swish values, calls Swift and converts back.
//
//   swish-bridge <Module.symbols.json> <output.swift>
//
// `run bridge` (Tasks.swish) runs it on the standard library and on
// swift-system (for FilePath). A member is
// bridged only if every type in its signature is one Swish can pass or hold
// (see `supported`); the rest are left out, and counted on stderr.
import Foundation

// MARK: The symbol graph

struct Fragment: Decodable { let kind: String; let spelling: String }
struct Version: Decodable { let major: Int; let minor: Int? }
struct Availability: Decodable {
    let domain: String?
    let isUnconditionallyDeprecated: Bool?
    let isUnconditionallyUnavailable: Bool?
    let deprecated: Version?
    let obsoleted: Version?
    let introduced: Version?
}
struct Constraint: Decodable { var kind: String; var lhs: String; var rhs: String }
struct Symbol: Decodable {
    struct Kind: Decodable { let identifier: String }
    struct Identifier: Decodable { let precise: String }
    struct Extension: Decodable { let constraints: [Constraint]? }
    struct Generics: Decodable { let constraints: [Constraint]? }
    struct Doc: Decodable { struct Line: Decodable { let text: String }; let lines: [Line] }
    let kind: Kind
    let identifier: Identifier
    let pathComponents: [String]
    let declarationFragments: [Fragment]?
    let swiftExtension: Extension?
    let swiftGenerics: Generics?
    let availability: [Availability]?
    let accessLevel: String
    let docComment: Doc?
}
struct Relationship: Decodable {
    let kind: String; let source: String; let target: String; let targetFallback: String?
    let swiftConstraints: [Constraint]?
}
struct Graph: Decodable {
    struct Module: Decodable { let name: String }
    let module: Module
    let symbols: [Symbol]
    let relationships: [Relationship]
}

// MARK: Swift types

indirect enum SType: Equatable {
    struct Element: Equatable { let label: String?; let type: SType }
    case named(String, [SType])
    case member(SType, String)
    case array(SType)
    case dictionary(SType, SType)
    case optional(SType)
    case function([SType], SType, throwing: Bool)
    case tuple([Element])
    /// A parameter `S` where `S: Sequence, S.Element == E`: any sequence of
    /// E, which the glue passes as an array.
    case someSequence(SType)
}

struct Unsupported: Error { let reason: String }

/// Parses Swift's spelling of types and declarations, as far as bridging
/// needs; anything else is `Unsupported`.
struct Reader {
    var chars: [Character]
    var pos = 0

    init(_ text: String) { chars = Array(text) }

    var atEnd: Bool { skipSpacesCopy() >= chars.count }
    func peek(_ offset: Int = 0) -> Character? { pos + offset < chars.count ? chars[pos + offset] : nil }

    func skipSpacesCopy() -> Int {
        var p = pos
        while p < chars.count && chars[p].isWhitespace { p += 1 }
        return p
    }
    mutating func skipSpaces() { pos = skipSpacesCopy() }

    mutating func consume(_ text: String) -> Bool {
        pos = skipSpacesCopy()
        let target = Array(text)
        guard pos + target.count <= chars.count, Array(chars[pos..<pos + target.count]) == target else { return false }
        // A keyword mustn't run into an identifier.
        if let last = target.last, last.isLetter, pos + target.count < chars.count,
           chars[pos + target.count].isLetter || chars[pos + target.count].isNumber || chars[pos + target.count] == "_" { return false }
        pos += target.count
        return true
    }

    mutating func identifier() -> String? {
        pos = skipSpacesCopy()
        // `extension`: a keyword used as a name.
        if peek() == "`", let close = chars[(pos + 1)...].firstIndex(of: "`"), close > pos + 1 {
            defer { pos = close + 1 }
            return String(chars[(pos + 1)..<close])
        }
        var end = pos
        while end < chars.count, chars[end].isLetter || chars[end].isNumber || chars[end] == "_" { end += 1 }
        guard end > pos, !chars[pos].isNumber else { return nil }
        defer { pos = end }
        return String(chars[pos..<end])
    }

    /// `P & Q`, where `~Copyable` (a suppressed conformance) says nothing.
    mutating func protocols() throws -> [String] {
        var protocols: [String] = []
        repeat {
            let suppressed = consume("~")
            guard let name = identifier() else { throw Unsupported(reason: "constraint") }
            if !suppressed { protocols.append(name) }
        } while consume("&")
        return protocols
    }

    mutating func type() throws -> SType {
        var result: SType
        pos = skipSpacesCopy()
        for word in ["some ", "any ", "inout ", "borrowing ", "consuming ", "sending ", "__owned ", "__shared "] where consume(word.trimmingCharacters(in: .whitespaces)) {
            throw Unsupported(reason: word)
        }
        while consume("@escaping") {}
        if consume("@autoclosure") { throw Unsupported(reason: "@autoclosure") }
        if consume("[") {
            let element = try type()
            if consume(":") {
                let value = try type()
                guard consume("]") else { throw Unsupported(reason: "dictionary") }
                result = .dictionary(element, value)
            } else {
                guard consume("]") else { throw Unsupported(reason: "array") }
                result = .array(element)
            }
        } else if consume("(") {
            var elements: [SType.Element] = []
            if !consume(")") {
                repeat {
                    // A tuple's labels are kept; a function's parameters have none.
                    let save = pos
                    var label: String?
                    if let name = identifier(), consume(":") { label = name } else { pos = save }
                    elements.append(.init(label: label, type: try type()))
                } while consume(",")
                guard consume(")") else { throw Unsupported(reason: "tuple") }
            }
            var throwing = false
            if consume("throws") {
                // `throws(E)` with a generic E: throws whatever it throws.
                if consume("(") { _ = identifier(); _ = consume(")") }
                throwing = true
            }
            if consume("async") { throw Unsupported(reason: "async") }
            if consume("->") {
                result = .function(elements.map(\.type), try type(), throwing: throwing)
            } else if elements.count == 1 && elements[0].label == nil {
                result = elements[0].type
            } else {
                result = .tuple(elements)
            }
        } else {
            guard let name = identifier() else { throw Unsupported(reason: "type at \(String(chars[pos...]).prefix(20))") }
            var arguments: [SType] = []
            if peek() == "<" {
                pos += 1
                repeat { arguments.append(try type()) } while consume(",")
                guard consume(">") else { throw Unsupported(reason: "generic arguments") }
            }
            result = .named(name, arguments)
        }
        while true {
            if peek() == "?" { pos += 1; result = .optional(result); continue }
            if peek() == "!" { throw Unsupported(reason: "implicitly unwrapped") }
            if peek() == ".", let next = peek(1), next.isLetter {
                pos += 1
                guard let member = identifier() else { break }
                if member == "Type" || member == "Protocol" { throw Unsupported(reason: "metatype") }
                result = .member(result, member)
                continue
            }
            break
        }
        return result
    }
}

// MARK: Declarations

struct Parameter {
    let label: String?
    let name: String
    let type: SType
    let defaultText: String?
}

/// A member's declaration, as far as its text says; its constraints come
/// from the symbol graph.
struct Declaration {
    enum Kind { case method, property, initializer }
    let kind: Kind
    let name: String
    let isStatic: Bool
    let isMutating: Bool
    let isFailable: Bool
    /// Its own generic parameters, with the protocols written beside them.
    let generics: [String: [String]]
    let parameters: [Parameter]
    let returns: SType?
    let throwing: Bool
    let rethrowing: Bool
    /// `throws(E)`: E, a generic parameter only for the error.
    let typedError: String?
    /// Its `where` clause, which the graph doesn't always give separately.
    var constraints: [Constraint] = []
}

/// `A: P & Q, B == C`, as the graph writes constraints.
func whereConstraints(_ text: String) -> [Constraint] {
    var parts: [String] = []
    var depth = 0
    var current = ""
    for c in text {
        if "(<[".contains(c) { depth += 1 }
        if ")>]".contains(c) { depth -= 1 }
        if c == "," && depth == 0 { parts.append(current); current = ""; continue }
        current.append(c)
    }
    parts.append(current)
    var constraints: [Constraint] = []
    for part in parts {
        if let range = part.range(of: "==") {
            constraints.append(Constraint(kind: "sameType", lhs: part[..<range.lowerBound].trimmingCharacters(in: .whitespaces),
                                          rhs: part[range.upperBound...].trimmingCharacters(in: .whitespaces)))
        } else if let colon = part.firstIndex(of: ":") {
            let lhs = part[..<colon].trimmingCharacters(in: .whitespaces)
            for proto in part[part.index(after: colon)...].split(separator: "&") {
                let name = proto.trimmingCharacters(in: .whitespaces)
                if !name.hasPrefix("~") { constraints.append(Constraint(kind: "conformance", lhs: lhs, rhs: name)) }
            }
        }
    }
    return constraints
}

func parseDeclaration(_ text: String) throws -> Declaration {
    var reader = Reader(text)
    var isStatic = false
    var isMutating = false
    // Attributes and modifiers before the declaration itself.
    while true {
        reader.skipSpaces()
        if reader.peek() == "@" {
            reader.pos += 1
            _ = reader.identifier()
            if reader.peek() == "(" {
                var depth = 0
                repeat {
                    if reader.peek() == "(" { depth += 1 }
                    if reader.peek() == ")" { depth -= 1 }
                    reader.pos += 1
                } while depth > 0 && !reader.atEnd
            }
            continue
        }
        let save = reader.pos
        guard let word = reader.identifier() else { throw Unsupported(reason: "declaration") }
        switch word {
        case "static", "class": isStatic = true
        case "mutating": isMutating = true
        case "nonmutating", "public", "final", "override", "convenience", "required", "optional", "dynamic", "lazy", "nonisolated": break
        default: reader.pos = save
        }
        if reader.pos == save { break }
    }
    var generics: [String: [String]] = [:]
    var typedError: String?
    func genericParameters(_ reader: inout Reader) throws {
        guard reader.consume("<") else { return }
        repeat {
            guard let name = reader.identifier() else { throw Unsupported(reason: "generic parameter") }
            if reader.consume("...") { throw Unsupported(reason: "variadic generics") }
            generics[name, default: []] += reader.consume(":") ? try reader.protocols() : []
        } while reader.consume(",")
        guard reader.consume(">") else { throw Unsupported(reason: "generics") }
    }
    func parameterList(_ reader: inout Reader) throws -> [Parameter] {
        guard reader.consume("(") else { throw Unsupported(reason: "parameters") }
        var parameters: [Parameter] = []
        if reader.consume(")") { return parameters }
        repeat {
            guard let first = reader.identifier() else { throw Unsupported(reason: "parameter") }
            var name = first
            var label: String? = first
            if let second = reader.identifier() { name = second }
            if first == "_" { label = nil }
            guard reader.consume(":") else { throw Unsupported(reason: "parameter type") }
            let type = try reader.type()
            if reader.consume("...") { throw Unsupported(reason: "variadic") }
            var defaultText: String?
            if reader.consume("=") {
                // Up to the next comma or `)` at this depth.
                var depth = 0
                var text = ""
                while let c = reader.peek(), !(depth == 0 && (c == "," || c == ")")) {
                    if "([<".contains(c) { depth += 1 }
                    if ")]>".contains(c) { depth -= 1 }
                    text.append(c)
                    reader.pos += 1
                }
                defaultText = text.trimmingCharacters(in: .whitespaces)
            }
            parameters.append(Parameter(label: label, name: name, type: type, defaultText: defaultText))
        } while reader.consume(",")
        guard reader.consume(")") else { throw Unsupported(reason: "parameters end") }
        return parameters
    }
    func effects(_ reader: inout Reader) throws -> (throwing: Bool, rethrowing: Bool) {
        if reader.consume("async") { throw Unsupported(reason: "async") }
        if reader.consume("rethrows") { return (false, true) }
        if reader.consume("throws") {
            // `throws(E)`, E from a closure it's given: it rethrows.
            if reader.consume("(") {
                guard let error = reader.identifier(), reader.consume(")") else { throw Unsupported(reason: "typed throws") }
                typedError = error
                return (false, true)
            }
            return (true, false)
        }
        return (false, false)
    }

    if reader.consume("func") {
        guard let name = reader.identifier() else { throw Unsupported(reason: "operator") }
        try genericParameters(&reader)
        let parameters = try parameterList(&reader)
        let (throwing, rethrowing) = try effects(&reader)
        let returns = reader.consume("->") ? try reader.type() : nil
        var declaration = Declaration(kind: .method, name: name, isStatic: isStatic, isMutating: isMutating, isFailable: false,
                                      generics: generics, parameters: parameters, returns: returns,
                                      throwing: throwing, rethrowing: rethrowing, typedError: typedError)
        if reader.consume("where") { declaration.constraints = whereConstraints(String(reader.chars[reader.pos...])) }
        return declaration
    }
    if reader.consume("var") || reader.consume("let") {
        guard let name = reader.identifier(), reader.consume(":") else { throw Unsupported(reason: "property") }
        let type = try reader.type()
        return Declaration(kind: .property, name: name, isStatic: isStatic, isMutating: false, isFailable: false,
                           generics: [:], parameters: [], returns: type, throwing: false, rethrowing: false, typedError: nil)
    }
    if reader.consume("init") {
        let failable = reader.consume("?")
        if reader.consume("!") { throw Unsupported(reason: "init!") }
        try genericParameters(&reader)
        let parameters = try parameterList(&reader)
        let (throwing, rethrowing) = try effects(&reader)
        var declaration = Declaration(kind: .initializer, name: "init", isStatic: true, isMutating: false, isFailable: failable,
                                      generics: generics, parameters: parameters, returns: nil,
                                      throwing: throwing, rethrowing: rethrowing, typedError: typedError)
        if reader.consume("where") { declaration.constraints = whereConstraints(String(reader.chars[reader.pos...])) }
        return declaration
    }
    throw Unsupported(reason: "kind")
}

// MARK: Bridging

/// Swish's own values, and how Swift's are held in them.
nonisolated(unsafe) var leaves: [String: (annotation: String, from: (String) -> String, to: (String) -> String)] = [
    "Int": (".int", { "try Int(swishValue: \($0))" }, { "\($0).swishValue" }),
    "Double": (".double", { "try Double(swishValue: \($0))" }, { "\($0).swishValue" }),
    "Bool": (".bool", { "try Bool(swishValue: \($0))" }, { "\($0).swishValue" }),
    "String": (".string", { "try String(swishValue: \($0))" }, { "\($0).swishValue" }),
    "Character": (#".named("Character")"#, { "try bridgeCharacter(\($0))" }, { #"SwiftValue.make(\#($0), as: "Character")"# }),
    "Substring": (#".named("Substring")"#, { "try SwiftValue.unbox(Substring.self, \($0))" }, { #"SwiftValue.make(\#($0), as: "Substring")"# }),
]

/// Generic types Swish holds as they are, boxed (`SwiftValue`), with Swish's
/// values for their generic parameters: a `Set<Int>` is a `Set<Value>`.
let boxes: Set = ["Set", "ArraySlice", "Range", "ClosedRange"]

/// The protocols a type conforms to, as far as the checker needs to know.
let knownProtocols: Set = ["Equatable", "Hashable", "Comparable", "CustomStringConvertible", "Encodable", "Sequence",
                           "ExpressibleByStringLiteral"]
/// What Swish's values (the stand-in for every generic parameter) can be.
let valueProtocols: Set = ["Equatable", "Hashable", "Comparable"]
/// Constraints every Swish value meets, so they say nothing.
let alwaysMet: Set = ["Copyable", "Escapable", "Sendable", "SendableMetatype"]

struct BridgedType {
    /// `String`, `Set`.
    let name: String
    /// Its generic parameters, all of them.
    let parameters: [String]
    /// Those not fixed to a type (by `where Element == String`).
    var genericParameters: [String]
    var fixed: [String: SType] = [:]
    var associated: [String: SType] = [:]
    /// The protocols it conforms to that the checker knows, each with what
    /// its generic parameters must be for it.
    var conformances: [String: [String: [String]]] = [:]
    /// Every protocol it conforms to, for constraints like `Self: FixedWidthInteger`.
    var allConformances: Set<String> = []

    init(name: String, parameters: [String]) {
        self.name = name
        self.parameters = parameters
        self.genericParameters = parameters
    }
}

/// What a member's types are resolved against.
struct Context {
    var owner: BridgedType
    /// The member's own generic parameters, and the owner's.
    var generics: Set<String>
    /// Its parameters that are sequences, with their elements.
    var sequences: [String: SType] = [:]
}

/// The type a member's `Self` is.
func selfType(_ owner: BridgedType) -> SType {
    let arguments = owner.parameters.map { owner.fixed[$0] ?? .named($0, []) }
    switch owner.name {
    case "Array": return .array(arguments[0])
    case "Optional": return .optional(arguments[0])
    case "Dictionary": return .dictionary(arguments[0], arguments[1])
    default: return .named(owner.name, arguments)
    }
}

/// A type as a member of the context's owner sees it: `Self`, associated
/// types and sequence parameters replaced. Nil when it can't be bridged.
func resolve(_ type: SType, _ context: Context) -> SType? {
    let owner = context.owner
    switch type {
    case .named("Self", []):
        return selfType(owner)
    case .named(let name, let arguments):
        if arguments.isEmpty, let element = context.sequences[name] { return resolve(element, context).map(SType.someSequence) }
        if context.generics.contains(name) || owner.genericParameters.contains(name) { return arguments.isEmpty ? type : nil }
        if arguments.isEmpty, let target = owner.associated[name] { return resolve(target, context) }
        if name == "Void" { return .tuple([]) }
        let resolved = arguments.compactMap { resolve($0, context) }
        guard resolved.count == arguments.count else { return nil }
        if name == "Array", resolved.count == 1 { return .array(resolved[0]) }
        if name == "Optional", resolved.count == 1 { return .optional(resolved[0]) }
        if name == "Dictionary", resolved.count == 2 { return .dictionary(resolved[0], resolved[1]) }
        return .named(name, resolved)
    case .member(let base, let name):
        // `S.Element`, for a sequence parameter S.
        if case .named(let parameter, []) = base, let element = context.sequences[parameter] {
            return name == "Element" ? resolve(element, context) : nil
        }
        // `FilePath.Component`: a nested type that's bridged too.
        if case .named(let outer, []) = base, types["\(outer).\(name)"] != nil { return .named("\(outer).\(name)", []) }
        guard let resolvedBase = resolve(base, context) else { return nil }
        // `Self.Element`: a generic parameter (on Array) or an associated type.
        if resolvedBase == selfType(owner) {
            if owner.genericParameters.contains(name) { return .named(name, []) }
            if let target = owner.associated[name] { return resolve(target, context) }
        }
        // `Bound.Stride`, with Bound fixed to Int: Int's own.
        if case .named(let leaf, []) = resolvedBase, let other = types[leaf], let target = other.associated[name] {
            return resolve(target, Context(owner: other, generics: []))
        }
        return nil
    case .array(let element): return resolve(element, context).map(SType.array)
    case .optional(let wrapped): return resolve(wrapped, context).map(SType.optional)
    case .dictionary(let key, let value):
        guard let key = resolve(key, context), let value = resolve(value, context) else { return nil }
        return .dictionary(key, value)
    case .tuple(let elements):
        let resolved = elements.compactMap { element in resolve(element.type, context).map { SType.Element(label: element.label, type: $0) } }
        return resolved.count == elements.count ? .tuple(resolved) : nil
    case .function(let parameters, let result, let throwing):
        let resolved = parameters.compactMap { resolve($0, context) }
        guard resolved.count == parameters.count, let result = resolve(result, context) else { return nil }
        return .function(resolved, result, throwing: throwing)
    case .someSequence:
        return type
    }
}

/// A leaf type or a generic parameter: what can be in a box or a dictionary.
func isSimple(_ type: SType, generics: Set<String>) -> Bool {
    guard case .named(let name, []) = type else { return false }
    return leaves[name] != nil || generics.contains(name)
}

/// Whether Swish can hold or pass `type`: its values, the leaf types above,
/// generic parameters (as Swish values), boxes, and arrays, dictionaries,
/// optionals, tuples and closures of those. Closures only as parameters.
func supported(_ type: SType, generics: Set<String>, asParameter: Bool) -> Bool {
    switch type {
    case .named(let name, let arguments):
        if arguments.isEmpty { return isSimple(type, generics: generics) }
        return boxes.contains(name) && arguments.allSatisfy { isSimple($0, generics: generics) }
    case .array(let element), .optional(let element), .someSequence(let element):
        return supported(element, generics: generics, asParameter: false)
    case .dictionary(let key, let value):
        return isSimple(key, generics: generics) && isSimple(value, generics: generics)
    case .tuple(let elements):
        return elements.allSatisfy { element in
            if case .function = element.type { return false }
            return supported(element.type, generics: generics, asParameter: false)
        }
    case .function(let parameters, let result, _):
        return asParameter && parameters.allSatisfy { supported($0, generics: generics, asParameter: false) }
            && supported(result, generics: generics, asParameter: false)
    case .member:
        return false
    }
}

func annotation(_ type: SType) -> String {
    switch type {
    case .named(let name, []): return leaves[name]?.annotation ?? ".parameter(\(quoted(name)))"
    case .named(let name, let arguments): return ".generic(\(quoted(name)), [\(arguments.map(annotation).joined(separator: ", "))])"
    case .array(let element): return ".list(\(annotation(element)))"
    case .optional(let wrapped): return ".optional(\(annotation(wrapped)))"
    case .dictionary(let key, let value): return ".dictionary(\(annotation(key)), \(annotation(value)))"
    case .someSequence(let element): return ".someSequence(\(annotation(element)))"
    case .tuple(let elements):
        if elements.isEmpty { return ".void" }
        return ".tuple([" + elements.map { ".init(label: \($0.label.map(quoted) ?? "nil"), type: \(annotation($0.type)))" }.joined(separator: ", ") + "])"
    case .function(let parameters, let result, let throwing):
        return ".functionType([\(parameters.map(annotation).joined(separator: ", "))], \(annotation(result)), throws: \(throwing))"
    case .member: fatalError("unsupported \(type)")
    }
}

/// How Swift spells `type`, with Swish's values for generic parameters.
func spelling(_ type: SType) -> String {
    switch type {
    case .named(let name, []): return leaves[name] != nil ? name : "Value"
    case .named(let name, let arguments):
        return "\(name)<\(arguments.map(spelling).joined(separator: ", "))>"
    case .array(let element), .someSequence(let element): return "[\(spelling(element))]"
    case .optional(let wrapped): return "\(spelling(wrapped))?"
    case .dictionary(let key, let value): return "[\(spelling(key)): \(spelling(value))]"
    case .tuple(let elements):
        if elements.isEmpty { return "Void" }
        return "(" + elements.map { ($0.label.map { "\($0): " } ?? "") + spelling($0.type) }.joined(separator: ", ") + ")"
    case .function(let parameters, let result, let throwing):
        return "(\(parameters.map(spelling).joined(separator: ", ")))\(throwing ? " throws" : "") -> \(spelling(result))"
    case .member: fatalError("unsupported \(type)")
    }
}

/// A box's type as Swish holds it: its generic parameters all Swish values.
func canonical(_ name: String, _ arguments: [SType]) -> String {
    spelling(.named(name, arguments.map { _ in .named("Value", []) }))
}

/// Whether a type is a leaf, which converts, rather than a Swish value.
func isLeaf(_ type: SType) -> Bool {
    if case .named(let name, []) = type { return leaves[name] != nil }
    return false
}

/// Swift code turning the Swish value `value` into a `type`.
func fromSwish(_ value: String, _ type: SType) -> String {
    switch type {
    case .named(let name, []): return leaves[name]?.from(value) ?? value
    case .named(let name, let arguments):
        let box = "try SwiftValue.unbox(\(canonical(name, arguments)).self, \(value))"
        guard arguments.contains(where: isLeaf) else { return box }
        switch name {
        case "Range", "ClosedRange": return "try bridge\(name)(\(value)) { \(fromSwish("$0", arguments[0])) }"
        default: return "\(spelling(type))(\(box).map { \(fromSwish("$0", arguments[0])) })"
        }
    case .array(let element), .someSequence(let element):
        let items = if case .array = type { "try bridgeList(\(value))" } else { "try bridgeSequence(\(value))" }
        if case .named(let name, []) = element, leaves[name] == nil { return items }
        return "\(items).map { \(fromSwish("$0", element)) }"
    case .optional(let wrapped): return "(\(value) == .nothing ? nil : \(fromSwish(value, wrapped)))"
    case .dictionary(let key, let value2):
        guard isLeaf(key) || isLeaf(value2) else { return "try bridgeDictionary(\(value))" }
        return "try Dictionary(uniqueKeysWithValues: bridgeDictionary(\(value)).map { (\(fromSwish("$0.key", key)), \(fromSwish("$0.value", value2))) })"
    case .tuple(let elements):
        let labels = elements.map { $0.label.map(quoted) ?? "nil" }.joined(separator: ", ")
        let parts = elements.enumerated().map { index, element in
            (element.label.map { "\($0): " } ?? "") + fromSwish("t[\(index)]", element.type)
        }
        return "try bridgeTuple(\(value), [\(labels)]) { t in (\(parts.joined(separator: ", "))) }"
    case .function(let parameters, let result, _):
        let names = parameters.indices.map { "a\($0)" }
        let arguments = zip(names, parameters).map { toSwish($0, $1) }.joined(separator: ", ")
        let typed = zip(names, parameters).map { "\($0): \(spelling($1))" }.joined(separator: ", ")
        let call = "try bridgeClosure(shell, \(value))([\(arguments)])"
        if case .tuple(let elements) = result, elements.isEmpty { return "{ (\(typed)) throws -> Void in _ = \(call) }" }
        return "{ (\(typed)) throws -> \(spelling(result)) in \(fromSwish(call, result)) }"
    case .member: fatalError("unsupported \(type)")
    }
}

/// Swift code turning `swift`, a `type`, into a Swish value.
func toSwish(_ swift: String, _ type: SType) -> String {
    switch type {
    case .named(let name, []): return leaves[name]?.to(swift) ?? swift
    case .named(let name, let arguments):
        let typeName = quoted(name)
        guard arguments.contains(where: isLeaf) else { return "SwiftValue.make(\(swift), as: \(typeName))" }
        let bound = arguments[0]
        switch name {
        case "Range", "ClosedRange":
            return "bridgeBox(\(swift), as: \(typeName)) { r in \(canonical(name, arguments))(uncheckedBounds: (lower: \(toSwish("r.lowerBound", bound)), upper: \(toSwish("r.upperBound", bound)))) }"
        default:
            return "bridgeBox(\(swift), as: \(typeName)) { \(canonical(name, arguments))($0.map { \(toSwish("$0", bound)) }) }"
        }
    case .array(let element):
        if case .named(let name, []) = element, leaves[name] == nil { return ".list(\(swift))" }
        return ".list(\(swift).map { \(toSwish("$0", element)) })"
    case .optional(let wrapped): return "(\(swift).map { \(toSwish("$0", wrapped)) } ?? .nothing)"
    case .dictionary(let key, let value):
        // In the receiver's order, as far as it goes.
        guard isLeaf(key) || isLeaf(value) else { return "bridgeDictionary(\(swift))" }
        return "bridgeDictionary(Dictionary(uniqueKeysWithValues: \(swift).map { (\(toSwish("$0.key", key)), \(toSwish("$0.value", value))) }))"
    case .tuple(let elements):
        if elements.isEmpty { return ".nothing" }
        let parts = elements.enumerated().map { index, element in
            "(\(element.label.map(quoted) ?? "nil"), \(toSwish("t.\(index)", element.type)))"
        }
        return "bridgeTuple(\(swift)) { t in [\(parts.joined(separator: ", "))] }"
    case .someSequence, .function, .member: fatalError("unsupported \(type)")
    }
}

/// A Swish `Value` literal for a default that is one, like `true` or `1`.
func literalDefault(_ text: String) -> String? {
    if text == "true" || text == "false" { return ".literal(.bool(\(text)))" }
    if Int(text) != nil { return ".literal(.int(\(text)))" }
    if Double(text) != nil { return ".literal(.double(\(text)))" }
    if text == "nil" { return ".literal(.nothing)" }
    if text.hasPrefix("\""), text.hasSuffix("\""), !text.contains("\\(") { return ".literal(.string(\(text)))" }
    return nil
}

/// A member's name as Swift code writes it: a keyword in backticks.
func swiftName(_ name: String) -> String {
    ["extension", "default", "func", "import", "in", "is", "as", "operator"].contains(name) ? "`\(name)`" : name
}

func quoted(_ text: String) -> String {
    "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
}

// MARK: Main

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: swish-bridge <Module.symbols.json> <output.swift>\n".utf8))
    exit(2)
}
let graph = try JSONDecoder().decode(Graph.self, from: Data(contentsOf: URL(fileURLWithPath: arguments[1])))

/// What's bridged from each module: its types, with their generic
/// parameters, and the name of the list the output declares.
let modules: [String: (list: String, types: [(String, [String])])] = [
    "Swift": ("standardLibrary", [
        ("String", []), ("Substring", []), ("Character", []), ("Int", []), ("Double", []), ("Bool", []),
        ("Array", ["Element"]), ("ArraySlice", ["Element"]), ("Set", ["Element"]), ("Dictionary", ["Key", "Value"]),
        ("Optional", ["Wrapped"]), ("Range", ["Bound"]), ("ClosedRange", ["Bound"]),
    ]),
    // FilePath.Root is left out: the standard library's FilePath (SE-0529)
    // calls it Anchor.
    "SystemPackage": ("system", [("FilePath", []), ("FilePath.Component", []), ("FilePath.ComponentView", [])]),
]
guard let module = modules[graph.module.name] else {
    FileHandle.standardError.write(Data("swish-bridge: nothing to bridge from \(graph.module.name)\n".utf8))
    exit(2)
}
let bridgedTypeNames = module.types
// Types of other modules than Swift's are held as they are, boxed.
if graph.module.name != "Swift" {
    for (name, _) in bridgedTypeNames {
        leaves[name] = (".named(\(quoted(name)))", { "try SwiftValue.unbox(\(name).self, \($0))" }, { "SwiftValue.make(\($0), as: \(quoted(name)))" })
    }
}
/// Members Swish has its own way: the textual form of the types it
/// formats, and a dictionary's keys and values, which are arrays rather
/// than Swift's views.
let swishOwn: [String: Set<String>] = [
    "Array": ["description", "debugDescription"],
    "Optional": ["description", "debugDescription"],
    "Dictionary": ["description", "debugDescription", "keys", "values"],
]

var typeIDs: [[String]: String] = [:]
for symbol in graph.symbols where symbol.kind.identifier == "swift.struct" || symbol.kind.identifier == "swift.enum" {
    typeIDs[symbol.pathComponents] = symbol.identifier.precise
}
let symbolsByID = Dictionary(graph.symbols.map { ($0.identifier.precise, $0) }, uniquingKeysWith: { first, _ in first })

/// Range and ClosedRange are sequences, and have most of their members,
/// only when `Bound: Strideable` with a SignedInteger stride: for Swish,
/// when Bound is Int.
func strideFix(_ constraint: Constraint) -> Bool {
    constraint.kind == "conformance" && constraint.rhs == "Strideable" && constraint.lhs == "Bound"
}

nonisolated(unsafe) var types: [String: BridgedType] = [:]
for (name, parameters) in bridgedTypeNames {
    var type = BridgedType(name: name, parameters: parameters)
    let path = name.split(separator: ".").map(String.init)
    for symbol in graph.symbols where symbol.pathComponents.dropLast() == path[...]
        && symbol.kind.identifier == "swift.typealias" {
        let text = (symbol.declarationFragments ?? []).map(\.spelling).joined()
        guard let equals = text.range(of: "=") else { continue }
        var reader = Reader(String(text[equals.upperBound...]))
        if let target = try? reader.type() { type.associated[symbol.pathComponents.last!] = target }
    }
    types[name] = type
}
for (name, _) in bridgedTypeNames {
    var type = types[name]!
    let id = typeIDs[name.split(separator: ".").map(String.init)]
    for relationship in graph.relationships where relationship.kind == "conformsTo" && relationship.source == id {
        var proto = relationship.targetFallback.map { String($0.split(separator: ".").last!) }
            ?? symbolsByID[relationship.target]?.pathComponents.last ?? ""
        type.allConformances.insert(proto)
        if proto == "Collection" || proto == "BidirectionalCollection" { proto = "Sequence" }
        guard knownProtocols.contains(proto) else { continue }
        // What the generic parameters must be for it, if Swish can say.
        var needs: [String: [String]] = [:]
        var sayable = true
        for constraint in relationship.swiftConstraints ?? [] where !alwaysMet.contains(constraint.rhs) {
            if strideFix(constraint) { needs["Bound"] = ["=Int"]; continue }
            if constraint.lhs.contains(".") { continue } // Bound.Stride, with Bound an Int
            if valueProtocols.contains(constraint.rhs) || constraint.rhs == "Encodable" {
                if needs[constraint.lhs] != ["=Int"] { needs[constraint.lhs, default: []].append(constraint.rhs) }
            } else {
                sayable = false
            }
        }
        guard sayable else { continue }
        // Of a conformance declared more than once, the least demanding.
        if let existing = type.conformances[proto], existing.values.map(\.count).reduce(0, +) <= needs.values.map(\.count).reduce(0, +) { continue }
        type.conformances[proto] = needs.mapValues { Array(Set($0)).sorted() }
    }
    types[name] = type
}

/// Whether a concrete type conforms to `proto`, for constraints on them.
func conforms(_ type: SType, _ proto: String) -> Bool {
    guard case .named(let name, []) = type else { return false }
    return types[name]?.allConformances.contains(proto) ?? false
}

func available(_ symbol: Symbol) -> Bool {
    for entry in symbol.availability ?? [] {
        if entry.isUnconditionallyDeprecated == true || entry.isUnconditionallyUnavailable == true { return false }
        // Obsoleted in the language itself (domain "Swift") counts too.
        if entry.domain == "Swift" || entry.domain == "SwiftPM", entry.obsoleted != nil || entry.deprecated != nil { return false }
        guard entry.domain == nil || entry.domain == "macOS" || entry.domain == "*" else { continue }
        if entry.deprecated != nil || entry.obsoleted != nil { return false }
        if let introduced = entry.introduced, entry.domain == "macOS",
           introduced.major > 14 || introduced.major == 14 && (introduced.minor ?? 0) > 0 { return false }
    }
    return true
}

func parseType(_ text: String) throws -> SType {
    var reader = Reader(text)
    return try reader.type()
}

/// `S.Element` for a sequence parameter S: S.
func sequenceParameter(_ type: SType, _ sequences: Set<String>) -> String? {
    if case .member(.named(let parameter, []), "Element") = type, sequences.contains(parameter) { return parameter }
    return nil
}

/// The Swift for one member: its signature and glue.
func bridge(_ symbol: Symbol, of original: BridgedType, given conditions: [Constraint] = []) throws -> (key: String, code: String) {
    let text = (symbol.declarationFragments ?? []).map(\.spelling).joined()
    let declaration = try parseDeclaration(text)
    if declaration.isMutating && declaration.isStatic { throw Unsupported(reason: "mutating") }
    var owner = original
    let constraints = conditions + (symbol.swiftExtension?.constraints ?? []) + (symbol.swiftGenerics?.constraints ?? [])
        + declaration.constraints
    var ownGenerics = declaration.generics
    if let error = declaration.typedError { ownGenerics.removeValue(forKey: error) }

    // Its generic parameters that are sequences: `S: Sequence`.
    var sequenceNames = Set(ownGenerics.filter { $0.value.contains("Sequence") }.keys)
    for constraint in constraints where constraint.kind == "conformance" && constraint.rhs == "Sequence"
        && ownGenerics[constraint.lhs] != nil { sequenceNames.insert(constraint.lhs) }
    var sequences: [String: SType] = [:]
    var fixed: [String: SType] = [:]
    for constraint in constraints where strideFix(constraint) && owner.genericParameters.contains("Bound") {
        fixed["Bound"] = .named("Int", [])
    }
    for constraint in constraints where constraint.kind == "sameType" {
        let lhs = try parseType(constraint.lhs), rhs = try parseType(constraint.rhs)
        if let parameter = sequenceParameter(lhs, sequenceNames) { sequences[parameter] = rhs; continue }
        if let parameter = sequenceParameter(rhs, sequenceNames) { sequences[parameter] = lhs; continue }
        // `where Element == String`: the member is for that element only, so
        // it's bridged with Element fixed to it.
        let name = constraint.lhs.replacingOccurrences(of: "Self.", with: "")
        guard owner.genericParameters.contains(name), isLeaf(rhs) else { throw Unsupported(reason: "same-type constraint") }
        fixed[name] = rhs
    }
    for (parameter, type) in fixed {
        owner.associated[parameter] = type
        owner.fixed[parameter] = type
        owner.genericParameters.removeAll { $0 == parameter }
    }
    // A sequence whose elements aren't said: its own generic parameter.
    for parameter in sequenceNames where sequences[parameter] == nil {
        sequences[parameter] = .named("\(parameter).Element", [])
        ownGenerics["\(parameter).Element"] = []
    }
    let methodGenerics = Set(ownGenerics.keys).subtracting(sequenceNames).subtracting(owner.genericParameters)
    let allGenerics = methodGenerics.union(owner.genericParameters)
    let context = Context(owner: owner, generics: allGenerics, sequences: sequences)

    // Constraints from the member and from the extension it's in.
    var needs: [String: [String]] = ownGenerics.filter { !sequenceNames.contains($0.key) }
    for constraint in constraints where constraint.kind == "conformance" {
        if constraint.lhs == declaration.typedError || alwaysMet.contains(constraint.rhs) { continue }
        if sequenceNames.contains(constraint.lhs) && constraint.rhs == "Sequence" { continue }
        guard let resolved = resolve(try parseType(constraint.lhs), context) else {
            throw Unsupported(reason: "constraint on \(constraint.lhs)")
        }
        if case .named(let parameter, []) = resolved, allGenerics.contains(parameter) {
            needs[parameter, default: []].append(constraint.rhs)
        } else if resolved == selfType(owner) {
            guard owner.allConformances.contains(constraint.rhs) else { throw Unsupported(reason: "Self: \(constraint.rhs)") }
        } else if !conforms(resolved, constraint.rhs) {
            throw Unsupported(reason: "\(constraint.lhs): \(constraint.rhs)")
        }
    }
    var generics: [String: [String]] = [:]
    for (parameter, protocols) in needs {
        let relevant = Set(protocols).subtracting(alwaysMet)
        guard relevant.allSatisfy(valueProtocols.contains) else { throw Unsupported(reason: "constraint \(relevant.sorted())") }
        generics[parameter] = relevant.sorted()
    }
    // A parameter fixed by `where Element == String` must be that type,
    // which the checker checks as a constraint written `=String`.
    for (parameter, type) in fixed {
        if case .named(let leaf, []) = type { generics[parameter] = ["=" + leaf] }
    }
    for parameter in allGenerics where generics[parameter] == nil { generics[parameter] = [] }

    var parameters: [(Parameter, SType)] = []
    for parameter in declaration.parameters {
        guard let type = resolve(parameter.type, context), supported(type, generics: allGenerics, asParameter: true) else {
            throw Unsupported(reason: "parameter \(parameter.type)")
        }
        parameters.append((parameter, type))
    }
    var returns: SType = .tuple([])
    if declaration.kind == .initializer {
        returns = selfType(owner)
        if declaration.isFailable { returns = .optional(returns) }
    } else if let declared = declaration.returns {
        guard let type = resolve(declared, context), supported(type, generics: allGenerics, asParameter: false) else {
            throw Unsupported(reason: "result \(declared)")
        }
        if case .someSequence = type { throw Unsupported(reason: "result \(declared)") }
        returns = type
    }
    // A method-level generic parameter that isn't in a parameter can't be
    // inferred by the glue.
    for parameter in methodGenerics {
        let mentioned = parameters.contains { annotation($0.1).contains("\"\(parameter)\"") }
        if !mentioned { throw Unsupported(reason: "uninferrable generic \(parameter)") }
    }

    let key = "\(declaration.kind) \(declaration.isStatic) \(declaration.name)(" + parameters.map { "\($0.0.label ?? "_"):\(annotation($0.1))" }.joined(separator: ",") + ")"

    // The signature.
    let parameterCode = parameters.map { parameter, type in
        var fields = ["label: \(parameter.label.map(quoted) ?? "nil")", "name: \(quoted(parameter.name))", "type: \(annotation(type))"]
        if let text = parameter.defaultText {
            if let literal = literalDefault(text) { fields.append("defaultValue: \(literal)") }
            else { fields.append("externalDefault: \(quoted(text))") }
        }
        return "Parameter(\(fields.joined(separator: ", ")))"
    }
    // The glue.
    let arguments = parameters.map { parameter, type -> String in
        let value = "args[\(quoted(parameter.name))]"
        var expr = fromSwish("\(value)!", type)
        if let text = parameter.defaultText, literalDefault(text) == nil {
            expr = "(\(value) == nil ? \(text) : \(fromSwish("\(value)!", type)))"
        }
        return (parameter.label.map { "\($0): " } ?? "") + expr
    }.joined(separator: ", ")
    let receiverType = selfType(owner)
    let swiftType = spelling(receiverType)
    let target: String
    switch declaration.kind {
    case .initializer: target = "\(swiftType)(\(arguments))"
    case .method: target = (declaration.isStatic ? swiftType : "receiver") + ".\(swiftName(declaration.name))(\(arguments))"
    case .property: target = (declaration.isStatic ? swiftType : "receiver") + ".\(swiftName(declaration.name))"
    }
    let tryPrefix = declaration.throwing || declaration.rethrowing ? "try " : ""
    var body = ""
    if !declaration.isStatic && declaration.kind != .initializer {
        let binding = declaration.isMutating ? "var" : "let"
        body += "\(binding) receiver: \(swiftType) = \(fromSwish("args[\"self\"]!", receiverType))\n                "
    }
    let isVoid = if case .tuple(let elements) = returns, elements.isEmpty { true } else { false }
    if declaration.isMutating {
        // The result, and the receiver as the call left it, for the shell to
        // put back where it came from (see `Shell.runBridged`).
        body += isVoid ? "\(tryPrefix)\(target)\n                " : "let result = \(tryPrefix)\(target)\n                "
        body += "return .list([\(isVoid ? ".nothing" : toSwish("result", returns)), \(toSwish("receiver", receiverType))])"
    } else if isVoid {
        body += "\(tryPrefix)\(target)\n                return .nothing"
    } else {
        body += "let result = \(tryPrefix)\(target)\n                return \(toSwish("result", returns))"
    }
    let kind = declaration.kind == .initializer ? ".initializer" : declaration.kind == .property ? ".property" : ".method"
    // `var extension: String? { get set }`: a setter too, which changes a
    // copy of the receiver and gives it back, as a mutating method does.
    var setter = ""
    if declaration.kind == .property, !declaration.isStatic, text.contains("set }") {
        setter = """

                BridgedMember(
                    kind: .setter, name: \(quoted(declaration.name)), isStatic: false,
                    parameters: [Parameter(label: nil, name: "newValue", type: \(annotation(returns)))],
                    returns: .void, generics: [:],
                    isThrowing: false, isRethrowing: false, isMutating: true,
                    discardableResult: false,
                    body: .native { shell, args in
                        _ = shell
                        var receiver: \(swiftType) = \(fromSwish("args[\"self\"]!", receiverType))
                        receiver.\(swiftName(declaration.name)) = \(fromSwish("args[\"newValue\"]!", returns))
                        return .list([.nothing, \(toSwish("receiver", receiverType))])
                    }
                ),
"""
    }
    let genericsCode = generics.isEmpty ? "[:]" : "[" + generics.sorted { $0.key < $1.key }.map { "\(quoted($0.key)): [\($0.value.map(quoted).joined(separator: ", "))]" }.joined(separator: ", ") + "]"
    return (key, """
                BridgedMember(
                    kind: \(kind), name: \(quoted(declaration.name)), isStatic: \(declaration.isStatic),
                    parameters: [\(parameterCode.joined(separator: ", "))],
                    returns: \(annotation(returns)), generics: \(genericsCode),
                    isThrowing: \(declaration.throwing), isRethrowing: \(declaration.rethrowing), isMutating: \(declaration.isMutating),
                    discardableResult: \(text.contains("@discardableResult")),
                    body: .native { shell, args in
                        _ = shell
                        \(body)
                    }
                ),\(setter)
""")
}

var output = """
// Generated by swish-bridge from the \(graph.module.name) module's symbol graph.
// Don't edit: `run bridge` remakes it.
import Foundation
import SwishKit
\(graph.module.name == "Swift" ? "" : "import \(graph.module.name)\n")
extension Bridge {
    nonisolated(unsafe) static let \(module.list): [BridgedType] = [

"""
var skipped: [String: Int] = [:]
var counts: [String: Int] = [:]

for (name, _) in bridgedTypeNames {
    let owner = types[name]!
    var seen: Set<String> = []
    var members: [String] = []
    let kinds = ["swift.method", "swift.property", "swift.init", "swift.type.method", "swift.type.property"]
    // Its own members, then, for a range, those of the collection protocols
    // it conforms to when Bound is Int, which the graph doesn't list.
    let path = name.split(separator: ".").map(String.init)
    var candidates = graph.symbols.filter { $0.pathComponents.dropLast() == path[...] }.map { ($0, [Constraint]()) }
    if name == "Range" || name == "ClosedRange" {
        let conditions = [Constraint(kind: "conformance", lhs: "Bound", rhs: "Strideable"),
                          Constraint(kind: "conformance", lhs: "Bound.Stride", rhs: "SignedInteger")]
        let protocols: Set = ["Sequence", "Collection", "BidirectionalCollection", "RandomAccessCollection"]
        // A member the type has itself shadows the protocol's default.
        let own = Set(candidates.map { $0.0.pathComponents.last! })
        candidates += graph.symbols.filter {
            $0.pathComponents.count == 2 && protocols.contains($0.pathComponents[0]) && !own.contains($0.pathComponents[1])
        }.map { ($0, conditions) }
    }
    for (symbol, conditions) in candidates {
        guard kinds.contains(symbol.kind.identifier), symbol.accessLevel == "public", available(symbol) else { continue }
        let title = symbol.pathComponents.last!
        guard !title.hasPrefix("_"), title.first?.isLetter ?? false else { continue }
        if swishOwn[name]?.contains(title) ?? false { continue }
        do {
            let (key, code) = try bridge(symbol, of: owner, given: conditions)
            guard seen.insert(key).inserted else { continue }
            members.append(code)
            counts[name, default: 0] += 1
        } catch let unsupported as Unsupported {
            // SWISH_BRIDGE_DEBUG=Set: why each of a type's members is left out.
            if ProcessInfo.processInfo.environment["SWISH_BRIDGE_DEBUG"] == name {
                FileHandle.standardError.write(Data("\(title): \(unsupported.reason)\n".utf8))
            }
            skipped[unsupported.reason.split(separator: " ").first.map(String.init) ?? "?", default: 0] += 1
        }
    }
    let context = Context(owner: owner, generics: Set(owner.genericParameters))
    let associated = owner.associated.compactMap { key, value -> String? in
        guard let resolved = resolve(value, context), supported(resolved, generics: context.generics, asParameter: false) else { return nil }
        return "\(quoted(key)): \(annotation(resolved))"
    }.sorted()
    let conformances = owner.conformances.sorted { $0.key < $1.key }.map { proto, needs in
        let needsCode = needs.isEmpty ? "[:]" : "[" + needs.sorted { $0.key < $1.key }.map { "\(quoted($0.key)): [\($0.value.map(quoted).joined(separator: ", "))]" }.joined(separator: ", ") + "]"
        return "\(quoted(proto)): \(needsCode)"
    }
    output += """
        BridgedType(
            name: \(quoted(name)), genericParameters: [\(owner.parameters.map(quoted).joined(separator: ", "))],
            conformances: [\(conformances.isEmpty ? ":" : conformances.joined(separator: ", "))],
            associatedTypes: [\(associated.isEmpty ? ":" : associated.joined(separator: ", "))],
            members: [
\(members.joined(separator: "\n"))
            ]
        ),

"""
}
output += "    ]\n}\n"
try output.write(to: URL(fileURLWithPath: arguments[2]), atomically: true, encoding: .utf8)
let total = counts.values.reduce(0, +)
FileHandle.standardError.write(Data("bridged \(total) members (\(bridgedTypeNames.map { "\($0.0) \(counts[$0.0] ?? 0)" }.joined(separator: ", "))); left out: \(skipped.sorted { $0.value > $1.value }.prefix(12).map { "\($0.key) \($0.value)" }.joined(separator: ", "))\n".utf8))
