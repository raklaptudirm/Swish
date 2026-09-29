// Reads a Swift module's symbol graph and writes the Swift that bridges
// its types' members to Swish: each member's signature, for the checker,
// and glue that converts Swish values, calls Swift and converts back.
//
//   swish-bridge <Swift.symbols.json> <output.swift>
//
// scripts/generate-bridge.sh runs it on the standard library. A member is
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
struct Constraint: Decodable { let kind: String; let lhs: String; let rhs: String }
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
struct Relationship: Decodable { let kind: String; let source: String; let target: String; let targetFallback: String? }
struct Graph: Decodable { let symbols: [Symbol]; let relationships: [Relationship] }

// MARK: Swift types

indirect enum SType: Equatable {
    case named(String, [SType])
    case member(SType, String)
    case array(SType)
    case dictionary(SType, SType)
    case optional(SType)
    case function([SType], SType, throwing: Bool)
    case tuple([SType])
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
        var end = pos
        while end < chars.count, chars[end].isLetter || chars[end].isNumber || chars[end] == "_" { end += 1 }
        guard end > pos, !chars[pos].isNumber else { return nil }
        defer { pos = end }
        return String(chars[pos..<end])
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
            var elements: [SType] = []
            if !consume(")") {
                repeat {
                    // A tuple's labels are dropped; a function's parameters have none.
                    let save = pos
                    if let _ = identifier(), consume(":") {} else { pos = save }
                    elements.append(try type())
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
                result = .function(elements, try type(), throwing: throwing)
            } else if elements.count == 1 {
                result = elements[0]
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

struct Declaration {
    enum Kind { case method, property, initializer }
    /// `throws(E)`: E, a generic parameter only for the error.
    var typedError: String? = nil
    /// `where Element == String`: a parameter fixed to a type.
    var fixed: [String: SType] = [:]
    let kind: Kind
    let name: String
    let isStatic: Bool
    let isMutating: Bool
    let isFailable: Bool
    let generics: [String: [String]]
    let sameTypes: Bool
    let parameters: [Parameter]
    let returns: SType?
    let throwing: Bool
    let rethrowing: Bool
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
    var sameTypes = false
    var typedError: String?
    var fixed: [String: SType] = [:]
    func genericParameters(_ reader: inout Reader) throws {
        guard reader.consume("<") else { return }
        repeat {
            guard let name = reader.identifier() else { throw Unsupported(reason: "generic parameter") }
            if reader.consume("...") { throw Unsupported(reason: "variadic generics") }
            var protocols: [String] = []
            if reader.consume(":") {
                repeat {
                    guard let proto = reader.identifier() else { throw Unsupported(reason: "constraint") }
                    protocols.append(proto)
                } while reader.consume("&")
            }
            generics[name, default: []] += protocols
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
    func whereClause(_ reader: inout Reader) throws {
        guard reader.consume("where") else { return }
        repeat {
            let lhs = try reader.type()
            if reader.consume("==") {
                let rhs = try reader.type()
                if case .named(let name, []) = lhs { fixed[name] = rhs } else { sameTypes = true }
                continue
            }
            guard reader.consume(":") else { throw Unsupported(reason: "where") }
            var protocols: [String] = []
            repeat {
                guard let proto = reader.identifier() else { throw Unsupported(reason: "where protocol") }
                protocols.append(proto)
            } while reader.consume("&")
            if case .named(let name, []) = lhs { generics[name, default: []] += protocols } else { sameTypes = true }
        } while reader.consume(",")
    }

    if reader.consume("func") {
        guard let name = reader.identifier() else { throw Unsupported(reason: "operator") }
        try genericParameters(&reader)
        let parameters = try parameterList(&reader)
        let (throwing, rethrowing) = try effects(&reader)
        let returns = reader.consume("->") ? try reader.type() : nil
        try whereClause(&reader)
        var declaration = Declaration(kind: .method, name: name, isStatic: isStatic, isMutating: isMutating, isFailable: false,
                                      generics: generics, sameTypes: sameTypes, parameters: parameters, returns: returns,
                                      throwing: throwing, rethrowing: rethrowing)
        declaration.typedError = typedError
        declaration.fixed = fixed
        return declaration
    }
    if reader.consume("var") || reader.consume("let") {
        guard let name = reader.identifier(), reader.consume(":") else { throw Unsupported(reason: "property") }
        let type = try reader.type()
        return Declaration(kind: .property, name: name, isStatic: isStatic, isMutating: false, isFailable: false,
                           generics: [:], sameTypes: false, parameters: [], returns: type, throwing: false, rethrowing: false)
    }
    if reader.consume("init") {
        let failable = reader.consume("?")
        if reader.consume("!") { throw Unsupported(reason: "init!") }
        try genericParameters(&reader)
        let parameters = try parameterList(&reader)
        let (throwing, rethrowing) = try effects(&reader)
        try whereClause(&reader)
        return Declaration(kind: .initializer, name: "init", isStatic: true, isMutating: false, isFailable: failable,
                           generics: generics, sameTypes: sameTypes, parameters: parameters, returns: nil,
                           throwing: throwing, rethrowing: rethrowing)
    }
    throw Unsupported(reason: "kind")
}

// MARK: Bridging

/// Swish's own values, and how Swift's are held in them.
nonisolated(unsafe) let leaves: [String: (annotation: String, from: (String) -> String, to: (String) -> String)] = [
    "Int": (".int", { "try Int(swishValue: \($0))" }, { "\($0).swishValue" }),
    "Double": (".double", { "try Double(swishValue: \($0))" }, { "\($0).swishValue" }),
    "Bool": (".bool", { "try Bool(swishValue: \($0))" }, { "\($0).swishValue" }),
    "String": (".string", { "try String(swishValue: \($0))" }, { "\($0).swishValue" }),
    "Character": (#".named("Character")"#, { "try bridgeCharacter(\($0))" }, { #"SwiftValue.make(\#($0), as: "Character")"# }),
    "Substring": (#".named("Substring")"#, { "try SwiftValue.unbox(Substring.self, \($0))" }, { #"SwiftValue.make(\#($0), as: "Substring")"# }),
]

/// The protocols a type conforms to, as far as the checker needs to know.
let knownProtocols: Set = ["Equatable", "Hashable", "Comparable", "CustomStringConvertible", "Encodable", "Sequence"]
/// What Swish's values (the stand-in for every generic parameter) can be.
let valueProtocols: Set = ["Equatable", "Hashable", "Comparable"]

struct BridgedType {
    let name: String
    var genericParameters: [String]
    var associated: [String: SType] = [:]
    var conformances: Set<String> = []
    /// Every protocol it conforms to, for constraints like `Self: FixedWidthInteger`.
    var allConformances: Set<String> = []
}

/// A type as the members of `owner` see it: `Self` and associated types
/// replaced. Nil when it can't be bridged.
func resolve(_ type: SType, in owner: BridgedType, generics: Set<String>) -> SType? {
    switch type {
    case .named("Self", []):
        return owner.genericParameters.isEmpty ? .named(owner.name, []) : .named(owner.name, owner.genericParameters.map { .named($0, []) })
    case .member(.named("Self", []), let associated), .member(.named(owner.name, _), let associated):
        // `Self.Element` on Array is its generic parameter.
        if owner.genericParameters.contains(associated) { return .named(associated, []) }
        guard let target = owner.associated[associated] else { return nil }
        return resolve(target, in: owner, generics: generics)
    case .named(let name, let arguments):
        if generics.contains(name) || owner.genericParameters.contains(name) { return arguments.isEmpty ? type : nil }
        if arguments.isEmpty, let target = owner.associated[name] { return resolve(target, in: owner, generics: generics) }
        if name == "Void" { return .tuple([]) }
        let resolved = arguments.compactMap { resolve($0, in: owner, generics: generics) }
        guard resolved.count == arguments.count else { return nil }
        if name == "Array", resolved.count == 1 { return .array(resolved[0]) }
        if name == "Optional", resolved.count == 1 { return .optional(resolved[0]) }
        return .named(name, resolved)
    case .member:
        return nil
    case .array(let element): return resolve(element, in: owner, generics: generics).map(SType.array)
    case .optional(let wrapped): return resolve(wrapped, in: owner, generics: generics).map(SType.optional)
    case .dictionary: return nil
    case .tuple(let elements): return elements.isEmpty ? type : nil
    case .function(let parameters, let result, let throwing):
        let resolved = parameters.compactMap { resolve($0, in: owner, generics: generics) }
        guard resolved.count == parameters.count, let result = resolve(result, in: owner, generics: generics) else { return nil }
        return .function(resolved, result, throwing: throwing)
    }
}

/// Whether Swish can hold or pass `type`: its values, the leaf types above,
/// generic parameters (as Swish values), and arrays, optionals and closures
/// of those. Closures only as parameters.
func supported(_ type: SType, generics: Set<String>, asParameter: Bool) -> Bool {
    switch type {
    case .named(let name, []): return leaves[name] != nil || generics.contains(name)
    case .array(let element), .optional(let element): return supported(element, generics: generics, asParameter: false)
    case .tuple(let elements): return elements.isEmpty
    case .function(let parameters, let result, _):
        return asParameter && parameters.allSatisfy { supported($0, generics: generics, asParameter: false) }
            && supported(result, generics: generics, asParameter: false)
    default: return false
    }
}

func annotation(_ type: SType) -> String {
    switch type {
    case .named(let name, []): return leaves[name]?.annotation ?? ".parameter(\"\(name)\")"
    case .array(let element): return ".list(\(annotation(element)))"
    case .optional(let wrapped): return ".optional(\(annotation(wrapped)))"
    case .tuple: return ".void"
    case .function(let parameters, let result, let throwing):
        return ".functionType([\(parameters.map(annotation).joined(separator: ", "))], \(annotation(result)), throws: \(throwing))"
    default: fatalError("unsupported \(type)")
    }
}

/// How Swift spells `type`, with Swish's values for generic parameters.
func spelling(_ type: SType) -> String {
    switch type {
    case .named(let name, []): return leaves[name] != nil ? name : "Value"
    case .array(let element): return "[\(spelling(element))]"
    case .optional(let wrapped): return "\(spelling(wrapped))?"
    case .tuple: return "Void"
    case .function(let parameters, let result, let throwing):
        return "(\(parameters.map(spelling).joined(separator: ", ")))\(throwing ? " throws" : "") -> \(spelling(result))"
    default: fatalError("unsupported \(type)")
    }
}

/// Swift code turning the Swish value `value` into a `type`.
func fromSwish(_ value: String, _ type: SType) -> String {
    switch type {
    case .named(let name, []): return leaves[name]?.from(value) ?? value
    case .array(let element):
        if case .named(let name, []) = element, leaves[name] == nil { return "try bridgeList(\(value))" }
        return "try bridgeList(\(value)).map { \(fromSwish("$0", element)) }"
    case .optional(let wrapped): return "(\(value) == .nothing ? nil : \(fromSwish(value, wrapped)))"
    case .function(let parameters, let result, _):
        let names = parameters.indices.map { "a\($0)" }
        let arguments = zip(names, parameters).map { toSwish($0, $1) }.joined(separator: ", ")
        let typed = zip(names, parameters).map { "\($0): \(spelling($1))" }.joined(separator: ", ")
        let call = "try bridgeClosure(shell, \(value))([\(arguments)])"
        if case .tuple = result { return "{ (\(typed)) throws -> Void in _ = \(call) }" }
        return "{ (\(typed)) throws -> \(spelling(result)) in \(fromSwish(call, result)) }"
    default: fatalError("unsupported \(type)")
    }
}

/// Swift code turning `swift`, a `type`, into a Swish value.
func toSwish(_ swift: String, _ type: SType) -> String {
    switch type {
    case .named(let name, []): return leaves[name]?.to(swift) ?? swift
    case .array(let element):
        if case .named(let name, []) = element, leaves[name] == nil { return ".list(\(swift))" }
        return ".list(\(swift).map { \(toSwish("$0", element)) })"
    case .optional(let wrapped): return "(\(swift).map { \(toSwish("$0", wrapped)) } ?? .nothing)"
    case .tuple: return ".nothing"
    default: fatalError("unsupported \(type)")
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

func quoted(_ text: String) -> String {
    "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
}

// MARK: Main

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: swish-bridge <Swift.symbols.json> <output.swift>\n".utf8))
    exit(2)
}
let graph = try JSONDecoder().decode(Graph.self, from: Data(contentsOf: URL(fileURLWithPath: arguments[1])))

/// The types bridged, with their generic parameters.
let bridgedTypeNames: [(String, [String])] = [
    ("String", []), ("Substring", []), ("Character", []), ("Int", []), ("Double", []), ("Bool", []), ("Array", ["Element"]),
]
var typeIDs: [String: String] = [:]
for symbol in graph.symbols where symbol.pathComponents.count == 1 && symbol.kind.identifier == "swift.struct" {
    typeIDs[symbol.pathComponents[0]] = symbol.identifier.precise
}
nonisolated(unsafe) var types: [String: BridgedType] = [:]
for (name, parameters) in bridgedTypeNames {
    var type = BridgedType(name: name, genericParameters: parameters)
    for symbol in graph.symbols where symbol.pathComponents.count == 2 && symbol.pathComponents[0] == name
        && symbol.kind.identifier == "swift.typealias" {
        let text = (symbol.declarationFragments ?? []).map(\.spelling).joined()
        guard let equals = text.range(of: "=") else { continue }
        var reader = Reader(String(text[equals.upperBound...]))
        if let target = try? reader.type() { type.associated[symbol.pathComponents[1]] = target }
    }
    let id = typeIDs[name]
    for relationship in graph.relationships where relationship.kind == "conformsTo" && relationship.source == id {
        let proto = relationship.targetFallback.map { String($0.split(separator: ".").last!) }
            ?? graph.symbols.first { $0.identifier.precise == relationship.target }?.pathComponents.last ?? ""
        type.allConformances.insert(proto)
        if knownProtocols.contains(proto) { type.conformances.insert(proto) }
        if proto == "Collection" || proto == "BidirectionalCollection" { type.conformances.insert("Sequence") }
    }
    types[name] = type
}

/// Whether a leaf type conforms to `proto`, for constraints on concrete types.
func conforms(_ type: SType, _ proto: String) -> Bool {
    guard case .named(let name, []) = type else { return false }
    return types[name]?.conformances.contains(proto) ?? false
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

var output = """
// Generated by swish-bridge from the Swift standard library's symbol graph.
// Don't edit: run scripts/generate-bridge.sh.
import Foundation
import SwishKit

extension Bridge {
    nonisolated(unsafe) static let standardLibrary: [BridgedType] = [

"""
var skipped: [String: Int] = [:]
var bridgedCount = 0

for (name, _) in bridgedTypeNames {
    let owner = types[name]!
    var seen: Set<String> = []
    var members: [String] = []
    for symbol in graph.symbols where symbol.pathComponents.count == 2 && symbol.pathComponents[0] == name {
        let kinds = ["swift.method", "swift.property", "swift.init", "swift.type.method", "swift.type.property"]
        guard kinds.contains(symbol.kind.identifier), symbol.accessLevel == "public", available(symbol) else { continue }
        let title = symbol.pathComponents[1]
        guard !title.hasPrefix("_"), title.first?.isLetter ?? false else { continue }
        let text = (symbol.declarationFragments ?? []).map(\.spelling).joined()
        do {
            let declaration = try parseDeclaration(text)
            if declaration.isMutating { throw Unsupported(reason: "mutating") }
            if declaration.sameTypes { throw Unsupported(reason: "same-type constraint") }
            // `where Element == String`: the member is for that element only, so
            // it's bridged with Element fixed to it.
            var owner = owner
            var fixed = declaration.fixed
            for constraint in symbol.swiftExtension?.constraints ?? [] where constraint.kind == "sameType" {
                var reader = Reader(constraint.rhs)
                let rhs = try reader.type()
                let lhs = constraint.lhs.replacingOccurrences(of: "Self.", with: "")
                guard owner.genericParameters.contains(lhs), case .named(let leaf, []) = rhs, leaves[leaf] != nil else {
                    throw Unsupported(reason: "same-type constraint")
                }
                fixed[lhs] = rhs
            }
            for (parameter, type) in fixed {
                guard owner.genericParameters.contains(parameter), case .named(let leaf, []) = type, leaves[leaf] != nil else {
                    throw Unsupported(reason: "same-type constraint")
                }
                owner.associated[parameter] = type
                owner.genericParameters.removeAll { $0 == parameter }
            }
            var declarationGenerics = declaration.generics
            if let error = declaration.typedError { declarationGenerics.removeValue(forKey: error) }
            let methodGenerics = Set(declarationGenerics.keys).subtracting(owner.genericParameters).subtracting(fixed.keys)
            let allGenerics = methodGenerics.union(owner.genericParameters)
            // Constraints from the member and from the extension it's in.
            var constraints = declarationGenerics
            for constraint in (symbol.swiftExtension?.constraints ?? []) + (symbol.swiftGenerics?.constraints ?? []) {
                if constraint.kind == "sameType" && (fixed[constraint.lhs.replacingOccurrences(of: "Self.", with: "")] != nil) { continue }
                if constraint.kind == "conformance" && constraint.lhs == declaration.typedError { continue }
                guard constraint.kind == "conformance" else { throw Unsupported(reason: "same-type constraint") }
                var reader = Reader(constraint.lhs)
                let lhs = try reader.type()
                guard let resolved = resolve(lhs, in: owner, generics: allGenerics) else { throw Unsupported(reason: "constraint on \(constraint.lhs)") }
                if case .named(let parameter, []) = resolved, allGenerics.contains(parameter) {
                    constraints[parameter, default: []].append(constraint.rhs)
                } else if case .named(owner.name, _) = resolved {
                    guard owner.allConformances.contains(constraint.rhs) || constraint.rhs == "Copyable" || constraint.rhs == "Escapable" else {
                        throw Unsupported(reason: "Self: \(constraint.rhs)")
                    }
                } else if !conforms(resolved, constraint.rhs) && constraint.rhs != "Copyable" && constraint.rhs != "Escapable" {
                    throw Unsupported(reason: "\(constraint.lhs): \(constraint.rhs)")
                }
            }
            var generics: [String: [String]] = [:]
            for (parameter, protocols) in constraints {
                let relevant = protocols.filter { $0 != "Copyable" && $0 != "Escapable" }
                guard relevant.allSatisfy(valueProtocols.contains) else { throw Unsupported(reason: "constraint \(relevant)") }
                generics[parameter] = Array(Set(relevant)).sorted()
            }
            // A parameter fixed by `where Element == String` must be that type,
            // which the checker checks as a constraint written `=String`.
            for (parameter, type) in fixed {
                if case .named(let leaf, []) = type { generics[parameter] = ["=" + leaf] }
            }
            for parameter in methodGenerics where generics[parameter] == nil { generics[parameter] = [] }
            for parameter in owner.genericParameters where generics[parameter] == nil { generics[parameter] = [] }

            var parameters: [(Parameter, SType)] = []
            for parameter in declaration.parameters {
                guard let type = resolve(parameter.type, in: owner, generics: allGenerics),
                      supported(type, generics: allGenerics, asParameter: true) else {
                    throw Unsupported(reason: "parameter \(parameter.type)")
                }
                parameters.append((parameter, type))
            }
            var returns: SType = .tuple([])
            if declaration.kind == .initializer {
                returns = .named(name, owner.genericParameters.map { .named($0, []) })
                if name == "Array" { returns = .array(.named("Element", [])) }
                if declaration.isFailable { returns = .optional(returns) }
            } else if let declared = declaration.returns {
                guard let type = resolve(declared, in: owner, generics: allGenerics),
                      supported(type, generics: allGenerics, asParameter: false) else {
                    throw Unsupported(reason: "result \(declared)")
                }
                returns = type
            }
            // A method-level generic parameter that isn't in a parameter can't be
            // inferred by the glue.
            for parameter in methodGenerics {
                let mentioned = parameters.contains { "\($0.1)".contains("\"\(parameter)\"") }
                if !mentioned { throw Unsupported(reason: "uninferrable generic \(parameter)") }
            }

            let key = "\(declaration.kind) \(declaration.isStatic) \(declaration.name)(" + parameters.map { "\($0.0.label ?? "_"):\(annotation($0.1))" }.joined(separator: ",") + ")"
            guard seen.insert(key).inserted else { continue }

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
            // Array's elements are Swish values, unless fixed to a type (`joined`).
            let receiverType: SType = name == "Array"
                ? .array(resolve(.named("Element", []), in: owner, generics: allGenerics) ?? .named("Element", []))
                : .named(name, [])
            let swiftType = name == "Array" ? "Array<Value>" : name
            let target: String
            switch declaration.kind {
            case .initializer: target = "\(swiftType)(\(arguments))"
            case .method: target = (declaration.isStatic ? swiftType : "receiver") + ".\(declaration.name)(\(arguments))"
            case .property: target = (declaration.isStatic ? swiftType : "receiver") + ".\(declaration.name)"
            }
            let tryPrefix = declaration.throwing || declaration.rethrowing ? "try " : ""
            var body = ""
            if !declaration.isStatic && declaration.kind != .initializer {
                body += "let receiver = \(fromSwish("args[\"self\"]!", receiverType))\n                "
            }
            if case .tuple = returns {
                body += "\(tryPrefix)\(target)\n                return .nothing"
            } else {
                body += "let result = \(tryPrefix)\(target)\n                return \(toSwish("result", returns))"
            }
            let kind = declaration.kind == .initializer ? ".initializer" : declaration.kind == .property ? ".property" : ".method"
            let genericsCode = generics.isEmpty ? "[:]" : "[" + generics.sorted { $0.key < $1.key }.map { "\(quoted($0.key)): [\($0.value.map(quoted).joined(separator: ", "))]" }.joined(separator: ", ") + "]"
            members.append("""
                BridgedMember(
                    kind: \(kind), name: \(quoted(declaration.name)), isStatic: \(declaration.isStatic),
                    parameters: [\(parameterCode.joined(separator: ", "))],
                    returns: \(annotation(returns)), generics: \(genericsCode),
                    isThrowing: \(declaration.throwing), isRethrowing: \(declaration.rethrowing),
                    body: .native { shell, args in
                        _ = shell
                        \(body)
                    }
                ),
""")
            bridgedCount += 1
        } catch let unsupported as Unsupported {
            skipped[unsupported.reason.split(separator: " ").first.map(String.init) ?? "?", default: 0] += 1
        }
    }
    let associated = owner.associated.compactMap { key, value -> String? in
        guard let resolved = resolve(value, in: owner, generics: Set(owner.genericParameters)),
              supported(resolved, generics: Set(owner.genericParameters), asParameter: false) else { return nil }
        return "\(quoted(key)): \(annotation(resolved))"
    }.sorted()
    output += """
        BridgedType(
            name: \(quoted(name)), genericParameters: [\(owner.genericParameters.map(quoted).joined(separator: ", "))],
            conformances: [\(owner.conformances.sorted().map(quoted).joined(separator: ", "))],
            associatedTypes: [\(associated.isEmpty ? ":" : associated.joined(separator: ", "))],
            members: [
\(members.joined(separator: "\n"))
            ]
        ),

"""
}
output += "    ]\n}\n"
try output.write(to: URL(fileURLWithPath: arguments[2]), atomically: true, encoding: .utf8)
FileHandle.standardError.write(Data("bridged \(bridgedCount) members; left out: \(skipped.sorted { $0.value > $1.value }.prefix(12).map { "\($0.key) \($0.value)" }.joined(separator: ", "))\n".utf8))
