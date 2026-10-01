import Foundation
import SwishKit

extension TypeChecker {
    // MARK: Fitting

    /// Whether a value of type `actual` can be used where `expected` is.
    func fits(_ actual: TypeAnnotation, _ expected: TypeAnnotation) -> Bool {
        if actual == expected || actual == .unknown || expected == .unknown || expected == .any { return true }
        switch (actual, expected) {
        case (.optional(let a), .optional(let b)): return fits(a, b)
        case (_, .optional(let wrapped)): return fits(actual, wrapped)
        case (.list(let a), .list(let b)): return fits(a, b)
        case (.dictionary(let ak, let av), .dictionary(let bk, let bv)): return fits(ak, bk) && fits(av, bv)
        case (.generic(let a, let aa), .generic(let b, let ba)):
            return a == b && aa.count == ba.count && zip(aa, ba).allSatisfy { fits($0, $1) }
        // Any sequence of the right elements, for a Swift `S: Sequence`.
        case (_, .someSequence(let element)):
            guard let actualElement = anySequenceElement(actual) else { return false }
            return fits(actualElement, element)
        case (.tuple(let a), .tuple(let b)):
            return a.count == b.count && zip(a, b).allSatisfy { x, y in
                (x.label == nil || y.label == nil || x.label == y.label) && fits(x.type, y.type)
            }
        case (.parameter, _), (_, .parameter): return true
        case (.keyPath(let ar, let av), .keyPath(let br, let bv)): return fits(br, ar) && fits(av, bv)
        case (.keyPath(let root, let value), .functionType(let parameters, let result, _)):
            return parameters.count == 1 && fits(parameters[0], root) && fits(value, result)
        case (.functionType, .function), (.function, .functionType), (.keyPath, .function): return true
        case (.functionType(let ap, let ar, let athrows), .functionType(let bp, let br, let bthrows)):
            // A function that throws can't be passed where one that doesn't is wanted.
            return ap.count == bp.count && zip(bp, ap).allSatisfy { fits($0, $1) }
                && (br == .void || fits(ar, br)) && (!athrows || bthrows)
        // A struct's value is a record, as builtins that take any record see it.
        case (.named(let name), .record): return structInfo(named: name) != nil
        case (.tuple, .record): return true
        // An Output is its text where a String is wanted, and its lines
        // where a [String] is.
        case (.output, .string), (.output, .list(.string)): return true
        default: return false
        }
    }
}

extension TypeChecker {
    // MARK: Protocols

    /// Whether `type` conforms to `proto`: as in Swift for the builtin types;
    /// a struct or enum by declaring it (an enum without associated values
    /// is Equatable and Hashable anyway, as in Swift).
    func conforms(_ type: TypeAnnotation, to proto: String) -> Bool {
        // `=String`: a bridged member for one element type only
        // (`joined(separator:)` where Element == String).
        if proto.hasPrefix("=") { return type == .unknown || type.description == String(proto.dropFirst()) }
        if type == TypeChecker.json { return true }
        if case .named(let name) = type, let bridgedType = Bridge.types[name] {
            return bridgedConforms(bridgedType, [:], to: proto)
        }
        if case .generic = type, let (bridgedType, bindings) = bridged(type) {
            return bridgedConforms(bridgedType, bindings, to: proto)
        }
        switch type {
        case .unknown, .parameter, .record: return true
        case .any, .function, .functionType, .void: return proto == "CustomStringConvertible"
        case .keyPath: return proto == "Equatable" || proto == "Hashable" || proto == "CustomStringConvertible"
        default: break
        }
        switch proto {
        case "CustomStringConvertible":
            return true
        case "Sequence":
            switch type {
            case .list, .dictionary, .output, .string: return true
            default: return false
            }
        case "Comparable":
            switch type {
            case .int, .double, .string, .filesize, .date: return true
            case .named(let name):
                if let info = enumInfo(named: name) {
                    return info.conformances.contains("Comparable") && info.cases.allSatisfy { $0.payload.isEmpty }
                }
                return false
            default: return false
            }
        case "Equatable", "Hashable", "Encodable":
            switch type {
            case .int, .double, .bool, .string, .filesize, .date: return true
            case .output: return proto == "Equatable"
            case .optional(let wrapped), .list(let wrapped): return conforms(wrapped, to: proto)
            case .dictionary(let key, let value): return conforms(key, to: "Hashable") && conforms(value, to: proto)
            // Tuples compare with `==`, but aren't Hashable or Encodable.
            case .tuple(let elements): return proto == "Equatable" && elements.allSatisfy { conforms($0.type, to: proto) }
            case .named(let name):
                if let info = structInfo(named: name) {
                    return info.conformances.contains(proto) || proto == "Equatable" && info.conformances.contains("Hashable")
                }
                if let info = enumInfo(named: name) {
                    if info.conformances.contains(proto) || proto == "Equatable" && info.conformances.contains("Hashable") { return true }
                    // Without associated values, an enum is Equatable and Hashable already.
                    return proto != "Encodable" && info.cases.allSatisfy { $0.payload.isEmpty }
                }
                return false
            default:
                return false
            }
        default:
            return false
        }
    }
}

extension TypeChecker {
    // MARK: Generics

    /// `type` with its type parameters replaced by what they're bound to;
    /// one not bound yet isn't known.
    func substitute(_ type: TypeAnnotation, _ bindings: [String: TypeAnnotation]) -> TypeAnnotation {
        switch type {
        case .parameter(let name): return bindings[name] ?? .unknown
        case .list(let element): return .list(substitute(element, bindings))
        case .optional(let wrapped): return .optional(substitute(wrapped, bindings))
        case .dictionary(let key, let value): return .dictionary(substitute(key, bindings), substitute(value, bindings))
        case .generic(let name, let arguments): return .generic(name, arguments.map { substitute($0, bindings) })
        case .someSequence(let element): return .someSequence(substitute(element, bindings))
        case .tuple(let elements): return .tuple(elements.map { .init(label: $0.label, type: substitute($0.type, bindings)) })
        case .keyPath(let root, let value): return .keyPath(substitute(root, bindings), substitute(value, bindings))
        case .functionType(let parameters, let result, let throwing):
            return .functionType(parameters.map { substitute($0, bindings) }, substitute(result, bindings), throws: throwing)
        default: return type
        }
    }

    /// Binds the type parameters in `pattern` by matching it with `actual`,
    /// the type an argument turned out to have.
    func unify(_ pattern: TypeAnnotation, _ actual: TypeAnnotation, _ bindings: inout [String: TypeAnnotation]) {
        switch (pattern, actual) {
        case (_, .unknown):
            return
        case (.parameter(let name), _):
            if bindings[name] == nil || bindings[name] == .unknown { bindings[name] = actual }
        case (.list(let p), .list(let a)), (.optional(let p), .optional(let a)):
            unify(p, a, &bindings)
        case (.optional(let p), _):
            unify(p, actual, &bindings)
        case (.dictionary(let pk, let pv), .dictionary(let ak, let av)):
            unify(pk, ak, &bindings)
            unify(pv, av, &bindings)
        case (.generic(let p, let ps), .generic(let a, let as_)) where p == a && ps.count == as_.count:
            for (p, a) in zip(ps, as_) { unify(p, a, &bindings) }
        case (.tuple(let ps), .tuple(let as_)) where ps.count == as_.count:
            for (p, a) in zip(ps, as_) { unify(p.type, a.type, &bindings) }
        case (.someSequence(let p), _):
            if let element = anySequenceElement(actual) { unify(p, element, &bindings) }
        case (.keyPath(let pr, let pv), .keyPath(let ar, let av)):
            unify(pr, ar, &bindings)
            unify(pv, av, &bindings)
        case (.keyPath(let pr, let pv), .functionType(let parameters, let result, _)) where parameters.count == 1:
            unify(pr, parameters[0], &bindings)
            unify(pv, result, &bindings)
        case (.functionType(let pp, let pr, _), .functionType(let ap, let ar, _)) where pp.count == ap.count:
            for (p, a) in zip(pp, ap) { unify(p, a, &bindings) }
            unify(pr, ar, &bindings)
        default:
            return
        }
    }

    /// The type of each item when iterating `type`.
    func elementType(of type: TypeAnnotation) throws -> TypeAnnotation {
        if case .named(let name) = type, let element = Bridge.types[name]?.associatedTypes["Element"] { return element }
        if case .generic = type {
            guard let element = bridgedElement(type) else { throw TypeError("can't iterate over \(type): it isn't a Sequence") }
            return element
        }
        switch type {
        case .list(let element): return element
        case .output, .string: return .string
        case .dictionary(let key, let value):
            return .tuple([.init(label: "key", type: key), .init(label: "value", type: value)])
        case .unknown, .any: return .unknown
        default: throw TypeError("can't iterate over \(type)")
        }
    }
}
