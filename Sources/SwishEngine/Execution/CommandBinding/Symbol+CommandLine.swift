import Swiit

extension Symbol {
    /// A function as Swift declares it: `greet(_ name: String, times: Int) -> String`. What a pipe
    /// feeds is marked `@input`.
    var signature: String {
        guard let function = function else { return name }
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

    /// The cases of an enum's members that carry nothing: what a word for the enum can be.
    static func plainCaseNames(of members: [Symbol]) -> [String] {
        members.compactMap { symbol in
            if case .enumCase(let parameters, _) = symbol.kind, parameters.isEmpty {
                return symbol.name
            }
            return nil
        }
    }
}
