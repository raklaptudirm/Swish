import Swiit

extension CallableSymbol {
    /// A function as Swift declares it: `greet(_ name: String, times: Int) -> String`. What a pipe
    /// feeds is marked `@input`.
    var usage: String {
        let function = signature
        let parameters = function.parameters.map { parameter -> String in
            let marked = CommandParameter(parameter, of: name)
            var text = marked.isInput ? "@input " : ""
            if parameter.label == parameter.name {
                text += parameter.name
            } else {
                text += "\(parameter.label ?? "_") \(parameter.name)"
            }
            return text + ": \(parameter.type)" + (parameter.arity == .variadic ? "..." : "")
        }
        return "\(name)(\(parameters.joined(separator: ", ")))"
            + (function.returns == .void ? "" : " -> \(function.returns)")
    }
}

extension Symbol {
    /// What a command can call, if the symbol is a function, a method or an initializer.
    var callable: (any CallableSymbol)? {
        switch self {
        case .function(let function): function
        case .method(let method): method
        case .initializer(let initializer): initializer
        default: nil
        }
    }

    /// How a call to it reads, or just its name for a symbol that cannot be called.
    var usage: String { callable?.usage ?? name }
}

extension Sequence where Element == Symbol {
    /// The global functions among them.
    var functions: [Symbol.Function] {
        compactMap { if case .function(let function) = $0 { function } else { nil } }
    }
}

extension Symbol {
    /// The cases of an enum's members that carry nothing: what a word for the enum can be.
    static func plainCaseNames(of members: [Symbol]) -> [String] {
        members.compactMap { symbol in
            if case .enumCase(let enumCase) = symbol, enumCase.payload.isEmpty {
                return symbol.name
            }
            return nil
        }
    }
}
