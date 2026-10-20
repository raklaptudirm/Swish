import Swiit

/// A parameter of a command: what Swiit says of it, and what the shell adds, which Swiit knows nothing of.
struct CommandParameter {
    var label: String?
    var name: String
    var type: ValueType
    var hasDefault: Bool
    var isVariadic: Bool
    var defaultValue: Value?
    var documentation: String?
    /// Receives what is piped in, per item or whole.
    var isInput = false
    /// `-a` for `--all`.
    var shortFlag: Character?

    init(_ parameter: Symbol.Parameter, of function: String, marks table: [String: CommandMarks.Marks] = CommandMarks.table) {
        label = parameter.label
        name = parameter.name
        type = parameter.type
        hasDefault = parameter.hasDefault
        isVariadic = parameter.isVariadic
        defaultValue = parameter.defaultValue
        documentation = parameter.documentation
        let marks = table["\(function).\(parameter.name)"] ?? CommandMarks.table["\(function).\(parameter.name)"]
        isInput = marks?.isInput ?? false
        shortFlag = marks?.shortFlag
    }

    init(label: String? = nil, name: String, type: ValueType, hasDefault: Bool = false, isVariadic: Bool = false, isInput: Bool = false) {
        self.label = label
        self.name = name
        self.type = type
        self.hasDefault = hasDefault
        self.isVariadic = isVariadic
        self.isInput = isInput
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

/// What the shell knows about a function's parameters that Swift's declaration can't say: which one a pipe feeds, and the short
/// flag of an option. Keyed `function.parameter`.
enum CommandMarks {
    struct Marks: Sendable {
        var isInput = false
        var shortFlag: Character?
    }

    static let table: [String: Marks] = [
        // The shell's own functions.
        "from.text": Marks(isInput: true),
        "to.items": Marks(isInput: true),
        "table.items": Marks(isInput: true),
        "list.items": Marks(isInput: true),
        "members.items": Marks(isInput: true),
        "ls.all": Marks(shortFlag: "a"),
        // Swiit's `sorted(by:)`.
        "sorted.key": Marks(shortFlag: "b"),
    ]
}

/// A function the shell can call as a command: the overloads of its name, and how the value it is a member of is given.
struct Callee {
    /// The name of the function, or of the method.
    var name: String
    /// One for each overload.
    var overloads: [Symbol]
    /// What the receiver is made of, for a method of what flows in; nil for a function by its name.
    var receiver: StageReceiver?
    /// What messages and help call it, when that is not its name: a script's `main` is the script.
    var shownName: String?
    /// What a script's own functions mark their parameters with (`@input`, `@flag("n")`), by `function.parameter`.
    var marks: [String: CommandMarks.Marks] = [:]

    var label: String { shownName ?? name }

    var parameters: [[CommandParameter]] {
        overloads.map { symbol in (symbol.function?.parameters ?? []).map { CommandParameter($0, of: name, marks: marks) } }
    }
}
