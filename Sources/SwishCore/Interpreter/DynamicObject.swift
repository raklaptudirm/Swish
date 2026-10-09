import SwishKit

/// A host object whose members aren't declared one by one: `env`, whose
/// members are the process's variables. Reading a member or indexing by a
/// string asks the object, assigning writes to it, and the checker types
/// every member the same, so `env.HOME` is a `String?` and `env.PAGER = "less"`
/// takes one.
///
/// It is a reference: assigning through a `let` binding is allowed, as with a
/// class in Swift. (A registered object is the Lua userdata with `__index` and
/// `__newindex`; the same feature serves JSON as a real type.)
package protocol DynamicObject: SwishObject {
    /// What reading any member, or indexing by a String, gives.
    var readType: TypeAnnotation { get }
    /// What assigning to a member takes; nil removes it, if that makes sense.
    var writeType: TypeAnnotation { get }
    /// The member called `name`; nothing when it has none.
    func read(_ name: String) throws -> Value
    func write(_ name: String, _ value: Value) throws
}

/// What the checker knows of a dynamic object's type, by its `typeName`.
package struct DynamicType {
    package var read: TypeAnnotation
    package var write: TypeAnnotation

    package init(read: TypeAnnotation, write: TypeAnnotation) {
        self.read = read
        self.write = write
    }
}

extension Interpreter {
    /// Binds `name` to a dynamic object in the outermost scope, and tells the
    /// checker the type of its members.
    package func bind(_ name: String, to object: some DynamicObject) {
        dynamicTypes[object.typeName] = DynamicType(read: object.readType, write: object.writeType)
        scopes[0].bindings[name] = Binding(value: .object(object), mutable: false)
    }
}

extension TypeChecker {
    /// The members' types if `type` is a dynamic object's.
    package func dynamicType(of type: TypeAnnotation) -> DynamicType? {
        guard case .named(let name) = type else { return nil }
        return interpreter.dynamicTypes[name]
    }
}

extension Value {
    /// Whether it is a dynamic object, which is assigned through, not replaced.
    package var isDynamicObject: Bool {
        if case .object(let object) = self { return object is DynamicObject }
        return false
    }
}
