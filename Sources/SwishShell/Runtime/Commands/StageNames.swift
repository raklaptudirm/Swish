import Foundation
import Swiit

// Which names can be a stage after a `|`: a member of what flows in. Known from the types, without a value in hand, for
// highlighting and completion, and for telling a method's name from a program's.

struct StageNames {
    /// Every member of Swift's own types a stage could call: one that reads its receiver without changing it.
    var all: Set<String> = []
    /// Those that are methods: a bare one, with nothing piped in, has nothing to work on (a property's name could be a program's).
    var methods: Set<String> = []
    /// The methods of the items as they come, which return the items as they come.
    var flow: Set<String> = []
    /// What every sequence has.
    var sequence: Set<String> = []
}

/// The names are the same for every shell in the process, once its types are registered, and costly to find.
private final class StageNameCache: @unchecked Sendable {
    static let shared = StageNameCache()
    private let lock = NSLock()
    private var cached: (types: Int, names: StageNames)?

    func names(types: Int, compute: () -> StageNames) -> StageNames {
        lock.lock()
        defer { lock.unlock() }
        if let cached, cached.types == types { return cached.names }
        let names = compute()
        cached = (types, names)
        return names
    }
}

extension Shell {
    func computeStageNames() -> StageNames {
        let count = interpreter.types().count
        return StageNameCache.shared.names(types: count) { findStageNames() }
    }

    private func findStageNames() -> StageNames {
        var names = StageNames()
        func add(_ symbol: Symbol) {
            if let function = symbol.function {
                guard !function.isMutating else { return }
                names.all.insert(symbol.name)
                names.methods.insert(symbol.name)
            } else if case .variable = symbol.declaration {
                names.all.insert(symbol.name)
            }
        }
        for type in interpreter.types() where type.isBuiltin {
            interpreter.symbols(of: .named(type.name)).forEach(add)
        }
        // What every sequence has.
        interpreter.symbols(of: .list(.any)).forEach(add)
        names.sequence = Set(interpreter.symbols(of: .named("Sequence")).filter { $0.function != nil }.map(\.name))
        for symbol in interpreter.symbols(of: .named("Flow", [.any])) {
            if case .named("Flow", _)? = symbol.function?.returns { names.flow.insert(symbol.name) }
        }
        return names
    }

    /// Whether some type has a member called `name` that a stage could call: a Swift type's, a struct's in scope, or a job's.
    func isMemberName(_ name: String) -> Bool {
        if stageNames.all.contains(name) || Job.members.contains(where: { $0.name == name }) { return true }
        return interpreter.types().contains { type in
            !type.isBuiltin && interpreter.symbols(named: name, of: .named(type.name)).contains { $0.function != nil }
        }
    }

    /// Whether `name` is a method some type has that a stage could call, and that makes no sense without something piped in.
    func isStageMethod(_ name: String) -> Bool {
        stageNames.methods.contains(name)
    }

    /// The members of a type named `name`, as a callee a stage can call on a receiver made as `receiver` says.
    func stageCallee(_ name: String, of type: ValueType, receiver: StageReceiver, includingMutating: Bool = false) -> Callee? {
        let members = interpreter.symbols(named: name, of: type).filter { symbol in
            if let function = symbol.function { return includingMutating || !function.isMutating }
            if case .variable = symbol.declaration { return true }
            return false
        }
        guard !members.isEmpty else { return nil }
        return Callee(name: name, overloads: members, receiver: receiver)
    }

    /// What `name` is after a `|`: a method of the items as they come (a `Flow`'s), or what every sequence has, or one of any
    /// type's. In the order the stage looks.
    func stageMethods(named name: String) -> Callee? {
        stageCallee(name, of: .named("Flow", [.any]), receiver: .flow)
            ?? stageCallee(name, of: .list(.any), receiver: .collected)
            ?? stageFunctions(named: name)
    }

    /// Every Swift type's stage members named `name`, as one callee: what's known of a stage while typing, before the type of
    /// what's piped into it is.
    func stageFunctions(named name: String) -> Callee? {
        let candidates = interpreter.types().filter(\.isBuiltin).sorted { $0.name < $1.name }.flatMap {
            stageCallee(name, of: .named($0.name), receiver: .collected)?.overloads ?? []
        }
        return candidates.isEmpty ? nil : Callee(name: name, overloads: candidates, receiver: .collected)
    }
}
