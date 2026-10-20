@_spi(Layer) import Swiit
import Foundation

// Spike: what a stage is, decided from what flows into it, when it flows. The front end emits `Command("sorted")` and nothing
// about the type; here the first item says what the items are, and the forms are looked up in the order the checker looked
// (the items as they come, the prelude's sequence methods, the items collected, a method of each item, each item's Swift
// members), then a function, then a program. Binding the stage's words to a candidate decides whether it fits.

/// What a stage is called on: the items collected, the items as they come, each item, or the one value.
enum StageReceiver: Equatable, Sendable {
    case collected, flow, each, value
}

struct DeferredStage {
    var name: String
    var arguments: [CommandArgument]
    var redirects: [ResolvedRedirect]
    var environment: [(String, String)]
    /// What it is if no form of a method fits: a function, or a program.
    var fallback: () throws -> Stage
}

private struct ConstraintFailure: Error { var message: String }

extension Shell {
    /// The stage `deferred` is, fed by `upstream`, and the stream to read in its place (the first item put back).
    /// `single`: the one value the pipeline started from, when it isn't a sequence.
    func resolve(_ deferred: DeferredStage, upstream: ValueStream, single: Value?) throws -> (stage: Stage, upstream: ValueStream) {
        let first = try upstream.next()
        var pending = first
        let replay = ValueStream {
            if let item = pending {
                pending = nil
                return item
            }
            return try upstream.next()
        }
        let name = deferred.name
        let checker = TypeChecker(interpreter: interpreter)
        let element = first.map(checker.type(of:)) ?? .unknown

        func function(_ set: OverloadSet) -> Stage {
            .function(set, deferred.arguments, redirects: deferred.redirects, environment: deferred.environment)
        }
        func bridged(_ receiverType: TypeAnnotation, _ receiver: StageReceiver) -> Stage? {
            guard let (type, bindings) = checker.bridged(receiverType) else { return nil }
            return bridgedStage(type.name, name, receiver: receiver, bindings: bindings).map(function)
        }

        var candidates: [() -> Stage?] = []
        // The one value a pipeline started from: its own members.
        if let single, index0(single, checker) {
            candidates.append { bridged(checker.type(of: single), .value) }
        }
        candidates.append { self.bridgedStage("Flow", name, receiver: .flow, bindings: ["Element": element]).map(function) }
        candidates.append { self.interpreter.sequenceMethods[name].map(function) }
        candidates.append { bridged(.list(element), .collected) }
        // A method of each item.
        candidates.append {
            guard let first else { return nil }
            switch first {
            case .record(let record) where record.typeName != nil:
                return (try? self.interpreter.member(name, of: first)) != nil ? .method(name, deferred.arguments, redirects: deferred.redirects, environment: deferred.environment) : nil
            case .object(let object) where !(object is SwiftValue):
                return object.member(name) != nil ? .method(name, deferred.arguments, redirects: deferred.redirects, environment: deferred.environment) : nil
            default: return nil
            }
        }
        // A member of each item's Swift type.
        if first != nil, !element.isUnknownType {
            candidates.append { bridged(element, .each) }
        }

        var firstFailure: Error?
        for candidate in candidates {
            guard let stage = candidate() else { continue }
            // It fits if its words bind to it: a stage is built to find out.
            if case .function(let set, let args, _, _) = stage {
                do {
                    let (chosen, _) = try interpreter.resolve(set) { try self.bind(commandLine: args, to: $0, excludingInput: true) }
                    // `[K.a] | sorted` needs its Element to be Comparable.
                    if first != nil, !element.isUnknownType,
                       let missing = (chosen.generics["Element"] ?? []).first(where: { !$0.hasPrefix("=") && !checker.conforms(element, to: $0) }) {
                        throw ConstraintFailure(message: "\(name) needs Element to be \(missing), and \(element) isn't")
                    }
                } catch let failure as ConstraintFailure {
                    throw RuntimeError(failure.message)
                } catch {
                    firstFailure = firstFailure ?? error
                    continue
                }
            }
            return (stage, replay)
        }
        // Something was a method of that name and its words did not fit: that says what is wrong, unless the name is
        // also a function or a program, which then is what it is.
        let fallback = try? deferred.fallback()
        if let firstFailure {
            switch fallback {
            case .function?: break
            case .external(let argv, _, _, _)? where Shell.shellBuiltins[argv[0]] != nil || findExecutable(argv[0]) != nil: break
            default: throw firstFailure
            }
        }
        return (try deferred.fallback(), replay)
    }

    /// Whether a value is the one value a pipeline starts from, not a sequence of items (as the checker told them apart).
    private func index0(_ value: Value, _ checker: TypeChecker) -> Bool {
        let type = checker.type(of: value)
        switch type {
        case .list: return false
        case .generic: return checker.bridgedElement(type) == nil
        case .named(let name): return Bridge.types[name]?.conformances["Sequence"] == nil
        default: return true
        }
    }
}

extension TypeAnnotation {
    var isUnknownType: Bool {
        switch self {
        case .unknown, .any: true
        default: false
        }
    }
}
