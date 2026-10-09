import SwishKit

/// What `await` waits for, which a host registers: the type of the operand
/// (a handle the host made), the type it gives, and how to wait. Without one,
/// `await` is refused. (A handle protocol is the real exit; docs/Design/async.md.)
package struct Awaiting {
    package var operand: TypeAnnotation
    package var result: TypeAnnotation
    /// Waits for the handle, or with no operand for the latest one; `throwing`
    /// for `try await`.
    package var perform: (_ handle: Value?, _ throwing: Bool) throws -> Value

    package init(operand: TypeAnnotation, result: TypeAnnotation, perform: @escaping (Value?, Bool) throws -> Value) {
        self.operand = operand
        self.result = result
        self.perform = perform
    }
}

extension Interpreter {
    /// Binds `name` in the outermost scope to a value worked out each time it
    /// is read, and tells the checker its type.
    package func bind(computed name: String, type: TypeAnnotation, _ value: @escaping () -> Value) {
        scopes[0].bindings[name] = Binding(computed: value)
        staticTypes[name] = type
    }
}
