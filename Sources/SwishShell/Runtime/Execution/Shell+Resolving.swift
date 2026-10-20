import Swiit
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
        let element = first.map(interpreter.valueType(of:)) ?? .any

        func function(_ callee: Callee) -> Stage {
            .function(callee, deferred.arguments, redirects: deferred.redirects, environment: deferred.environment)
        }

        var candidates: [() -> Stage?] = []
        // The one value a pipeline started from: its own members.
        if let single, single.items == nil {
            candidates.append { self.stageCallee(name, of: self.interpreter.valueType(of: single), receiver: .value).map(function) }
        }
        candidates.append { self.stageCallee(name, of: .named("Flow", [element]), receiver: .flow).map(function) }
        // The items collected: what every sequence has, and the list's own.
        candidates.append { self.stageCallee(name, of: .list(element), receiver: .collected).map(function) }
        // A member of each item's type: a struct's method, an object's, a Swift type's.
        if first != nil, !element.isUnknown {
            candidates.append { self.stageCallee(name, of: element, receiver: .each).map(function) }
        }

        var firstFailure: Error?
        for candidate in candidates {
            guard let stage = candidate() else { continue }
            // It fits if its words bind to it: a stage is built to find out.
            if case .function(let callee, let args, _, _) = stage {
                // A stage written as a call is bound as a call is: by the labels and types of its arguments.
                let written = args.compactMap { argument -> ValueType.Element? in
                    if case .call(let call) = argument { ValueType.Element(label: call.label, type: self.interpreter.valueType(of: call.value)) } else { nil }
                }
                do {
                    if !written.isEmpty {
                        _ = try interpreter.resolveOverload(among: callee.overloads, arguments: written)
                        return (stage, replay)
                    }
                    let shapes = args.map { argument -> CommandWordShape in
                        if case .text(let text) = argument { .text(text) } else { .closure }
                    }
                    let binding = try bindCommandLine(shapes, to: callee, excludingInput: true)
                    // `[K.a] | sorted` needs its Element to be Comparable.
                    if first != nil, !element.isUnknown,
                       let missing = (callee.overloads[binding.overload].function?.generics["Element"] ?? []).first(where: {
                           !$0.hasPrefix("=") && !self.interpreter.conforms(element, to: $0)
                       }) {
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
}
