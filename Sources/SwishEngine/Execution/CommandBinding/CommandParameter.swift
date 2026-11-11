import Swiit

/// A parameter of a command: what Swiit says of it, and what the shell adds, which Swiit knows
/// nothing of.
struct CommandParameter {
    var label: String?
    var name: String
    var type: ScriptType
    var arity: Symbol.Parameter.Arity
    var documentation: String?
    /// Receives what is piped in, per item or whole.
    var isInput = false
    /// `-a` for `--all`.
    var shortFlag: Character?
    /// Takes the field names that follow, as a closure that makes a tuple of them from an item.
    var picksFields = false

    init(
        _ parameter: Symbol.Parameter,
        of function: String,
        marks table: [String: CommandMarks.Marks] = CommandMarks.table
    ) {
        label = parameter.label
        name = parameter.name
        type = parameter.type
        arity = parameter.arity
        documentation = parameter.documentation
        let marks =
            table["\(function).\(parameter.name)"]
            ?? CommandMarks.table["\(function).\(parameter.name)"]
        isInput = marks?.isInput ?? false
        shortFlag = marks?.shortFlag
        picksFields = marks?.picksFields ?? false
    }

    init(
        label: String? = nil,
        name: String,
        type: ScriptType,
        arity: Symbol.Parameter.Arity = .required,
        isInput: Bool = false
    ) {
        self.label = label
        self.name = name
        self.type = type
        self.arity = arity
        self.isInput = isInput
    }

    var isVariadic: Bool { arity == .variadic }

    /// Takes every positional word left, not one.
    var takesRest: Bool { isVariadic || picksFields }

    var hasDefault: Bool {
        if case .defaulted = arity { return true }
        return false
    }

    /// What the call gets by leaving it out, when that is a plain value.
    var defaultValue: Value? {
        if case .defaulted(.value(let value)) = arity { return value }
        return nil
    }

    /// The word the shell writes for it: `--all`, `<paths>`.
    var commandLineName: String {
        label.map { "--\(kebabCase($0))" } ?? "<\(name)>"
    }
}

func kebabCase(_ label: String) -> String {
    label.reduce(into: "") { result, c in
        if c.isUppercase {
            result += "-" + c.lowercased()
        } else {
            result.append(c)
        }
    }
}

/// What the shell knows about a function's parameters that Swift's declaration can't say: which one
/// a pipe feeds, and the short flag of an option. Keyed `function.parameter`.
enum CommandMarks {
    /// What is marked on one parameter.
    struct Marks: Sendable {
        var isInput = false
        var shortFlag: Character?
        var picksFields = false
    }

    static let table: [String: Marks] = [
        // The shell's own functions.
        "from.text": Marks(isInput: true),
        "to.items": Marks(isInput: true),
        "table.items": Marks(isInput: true),
        "list.items": Marks(isInput: true),
        "members.items": Marks(isInput: true),
        "ls.all": Marks(shortFlag: "a"),
        // `select name size`: the words are field names, which make `{ (name: $0.name, size: $0.size) }`.
        "select.fields": Marks(picksFields: true),
        // Swiit's `sorted(by:)`.
        "sorted.key": Marks(shortFlag: "b"),
    ]
}

/// A function the shell can call as a command: the overloads of its name, and how the value it is a
/// member of is given.
struct Callee {
    /// The name of the function, or of the method.
    var name: String
    /// One for each overload.
    var overloads: [Symbol]
    /// What the receiver is made of, for a method of what flows in; nil for a function by its name.
    var receiver: StageReceiver?
    /// What messages and help call it, when that is not its name: a script's `main` is the script.
    var shownName: String?
    /// What a script's own functions mark their parameters with (`@input`, `@flag("n")`), by
    /// `function.parameter`.
    var marks: [String: CommandMarks.Marks] = [:]

    var label: String { shownName ?? name }

    var parameters: [[CommandParameter]] {
        overloads.map { symbol in
            (symbol.function?.parameters ?? []).map { CommandParameter($0, of: name, marks: marks) }
        }
    }
}
