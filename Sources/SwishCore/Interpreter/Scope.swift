import Foundation
import SwishKit

struct Binding {
    /// Builtin names whose values are live: read when they're used.
    enum Special {
        /// `env`: the environment, as a record; `env.NAME` is nil if unset.
        case environment
        /// `jobs`: the jobs in the background, oldest first.
        case jobs
        /// `self` in a struct's `init`, which may set its `let` properties.
        case initializing
    }

    /// Where the value lives, shared by every scope that has this
    /// variable: the one it was declared in, and closures that use it.
    let cell: Cell
    var value: Value {
        get { cell.value }
        nonmutating set { cell.value = newValue }
    }
    let mutable: Bool
    /// Declared with `func`, which makes it callable in command mode.
    var isFunction = false
    var special: Special?

    init(value: Value, mutable: Bool, isFunction: Bool = false, special: Special? = nil) {
        cell = Cell(value)
        self.mutable = mutable
        self.isFunction = isFunction
        self.special = special
    }

    /// A variable's storage, so a closure can share it without keeping the
    /// whole scope it's in.
    final class Cell {
        var value: Value
        init(_ value: Value) { self.value = value }
    }
}

/// A reference type so closures share variables with the scope they
/// captured, as in Swift.
final class Scope {
    var bindings: [String: Binding]
    /// For a closure's scope: where it was made, held weakly so it can't
    /// keep them alive, for names bound there after it was made (a local
    /// function declared further down).
    var fallbacks: [WeakScope] = []

    init(_ bindings: [String: Binding] = [:]) {
        self.bindings = bindings
    }

    /// Declares a function by its name: another of that name is overloaded,
    /// unless the signature is the same, which replaces it.
    func declare(_ function: Function, named name: String) {
        var candidates = [function]
        if let existing = bindings[name], existing.isFunction,
           case .function(let callable) = existing.value, let set = callable as? OverloadSet {
            candidates = set.candidates.filter { !$0.hasSameSignature(as: function) } + candidates
        }
        bindings[name] = Binding(value: .function(OverloadSet(name: name, candidates: candidates)), mutable: false, isFunction: true)
    }

    /// The scope binding `name`: this one, or where it was made.
    func holding(_ name: String) -> Scope? {
        if bindings[name] != nil { return self }
        for fallback in fallbacks.reversed() {
            if let scope = fallback.scope, scope.bindings[name] != nil { return scope }
        }
        return nil
    }
}

struct WeakScope {
    weak var scope: Scope?
}
