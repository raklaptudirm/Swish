/// What the shell lends a function that asks for it. A parameter of this type
/// is filled in when the function is called and is never a command-line
/// argument or a flag: `func history(in shell: ShellContext) -> [String]`.
public struct ShellContext: Sendable {
    /// What was entered at the prompt, oldest first.
    public let history: [String]
    /// Whether output to the terminal may be colored.
    public let colorOutput: Bool

    public init(history: [String], colorOutput: Bool) {
        self.history = history
        self.colorOutput = colorOutput
    }
}

/// What a function that carries on past a failure gives: its result, and
/// what went wrong on the way. The shell reports each error as an error in
/// one item, as it does for `ls` on a directory it can't read, with the
/// function's name before the error's description, and goes on with the
/// result.
public struct Partial<Value> {
    public var value: Value
    public var errors: [any Error]

    public init(_ value: Value, errors: [any Error] = []) {
        self.value = value
        self.errors = errors
    }
}

// MARK: Fields by name

/// How a value's field is read by name, set by the shell for the length of a
/// call that takes a key path: the shell knows what a record, a struct or an
/// object has.
public enum FieldAccess {
    nonisolated(unsafe) public static var reader: ((Value, String) -> Value)?
}

extension Value {
    /// A field by name, nil as `.nothing`: what a key path over values
    /// (`\Value.[field: "size"]`) reads, so a Swift function taking a
    /// `KeyPath<Element, V>` works on Swish's values as on Swift's.
    public subscript(field name: String) -> Value {
        FieldAccess.reader?(self, name) ?? .nothing
    }
}
