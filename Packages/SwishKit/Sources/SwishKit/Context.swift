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
/// one item, as it does for `ls` on a directory it can't read, and goes on
/// with the result.
public struct Partial<Value> {
    public var value: Value
    public var errors: [String]

    public init(_ value: Value, errors: [String] = []) {
        self.value = value
        self.errors = errors
    }
}
