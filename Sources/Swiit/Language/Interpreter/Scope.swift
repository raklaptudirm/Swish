import Foundation
import SwishKit

package struct Binding {
    package enum Special {
        /// `self` in a struct's `init`, which may set its `let` properties.
        case initializing
    }

    /// Where the value lives, shared by every scope that has this
    /// variable: the one it was declared in, and closures that use it.
    package let cell: Cell
    package var value: Value {
        get { cell.value }
        nonmutating set { cell.value = newValue }
    }
    package let mutable: Bool
    /// Its value is worked out on each read; looking at its type reads nothing.
    package var isComputed: Bool { cell.isComputed }
    /// Declared with `func`, which makes it callable in command mode.
    package var isFunction = false
    package var special: Special?

    package init(value: Value, mutable: Bool, isFunction: Bool = false, special: Special? = nil) {
        cell = Cell(value)
        self.mutable = mutable
        self.isFunction = isFunction
        self.special = special
    }

    /// A name whose value is worked out each time it is read, like the shell's
    /// `jobs`, and can't be assigned.
    package init(computed value: @escaping () -> Value) {
        cell = Cell(compute: value)
        mutable = false
    }

    /// A variable's storage, so a closure can share it without keeping the
    /// whole scope it's in.
    package final class Cell {
        private var stored: Value
        private let compute: (() -> Value)?

        package var value: Value {
            get { compute?() ?? stored }
            set { stored = newValue }
        }

        package init(_ value: Value) {
            stored = value
            compute = nil
        }

        /// Worked out on each read, not stored.
        package var isComputed: Bool { compute != nil }

        package init(compute: @escaping () -> Value) {
            stored = .nothing
            self.compute = compute
        }
    }
}

/// A reference type so closures share variables with the scope they
/// captured, as in Swift.
package final class Scope {
    package var bindings: [String: Binding]
    /// For a closure's scope: where it was made, held weakly so it can't
    /// keep them alive, for names bound there after it was made (a local
    /// function declared further down).
    package var fallbacks: [WeakScope] = []

    package init(_ bindings: [String: Binding] = [:]) {
        self.bindings = bindings
    }

    /// Declares a function by its name: another of that name is overloaded,
    /// unless the signature is the same, which replaces it.
    package func declare(_ function: Function, named name: String) {
        var candidates = [function]
        if let existing = bindings[name], existing.isFunction,
           case .function(let callable) = existing.value, let set = callable as? OverloadSet {
            candidates = set.candidates.filter { !$0.hasSameSignature(as: function) } + candidates
        }
        bindings[name] = Binding(value: .function(OverloadSet(name: name, candidates: candidates)), mutable: false, isFunction: true)
    }

    /// The scope binding `name`: this one, or where it was made.
    package func holding(_ name: String) -> Scope? {
        if bindings[name] != nil { return self }
        for fallback in fallbacks.reversed() {
            if let scope = fallback.scope, scope.bindings[name] != nil { return scope }
        }
        return nil
    }
}

package struct WeakScope {
    package weak var scope: Scope?
}
