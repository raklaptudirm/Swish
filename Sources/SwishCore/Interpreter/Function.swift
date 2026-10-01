import Foundation
import SwishKit

enum FunctionBody {
    case swish(Program)
    /// A builtin written in Swift, called with the bound arguments.
    case native((Shell, [String: Value]) throws -> Value)
    /// A builtin that transforms its `@input` stream lazily, so `first 5`
    /// can stop pulling after five items.
    case stream((Shell, ValueStream, [String: Value]) throws -> ValueStream)
}

/// A Swish function or closure, or a builtin written in Swift. Both get the
/// same argument binding, help, overloads and streaming.
final class Function: Callable, @unchecked Sendable {
    let name: String?
    let parameters: [Parameter]
    let returnType: TypeAnnotation?
    let body: FunctionBody
    let captured: [Scope]
    let documentation: Documentation?
    /// The imported module it came from, for a plugin's function.
    let plugin: String?
    /// A struct's `mutating func` (or `init`), which may change `self`.
    let isMutating: Bool
    /// `throws`: a call to it needs `try`.
    let isThrowing: Bool
    /// `rethrows`: a call throws if a closure passed to it does.
    let isRethrowing: Bool
    /// Type parameters and their constraints, for a generic builtin.
    let generics: [String: [String]]

    init(
        name: String?, parameters: [Parameter], returnType: TypeAnnotation?, body: FunctionBody,
        captured: [Scope] = [], documentation: Documentation? = nil, plugin: String? = nil, isMutating: Bool = false,
        isThrowing: Bool = false, isRethrowing: Bool = false, generics: [String: [String]] = [:]
    ) {
        self.isRethrowing = isRethrowing
        self.generics = generics
        self.plugin = plugin
        self.isMutating = isMutating
        self.isThrowing = isThrowing
        self.name = name
        self.parameters = parameters
        self.returnType = returnType
        self.body = body
        self.captured = captured
        self.documentation = documentation
    }

    var inputParameter: Parameter? {
        parameters.first(where: \.isInput)
    }

    /// Whether a new declaration would replace this one rather than overload it.
    func hasSameSignature(as other: Function) -> Bool {
        let signature = { (p: Parameter) in [p.label ?? "_", p.type.description, "\(p.variadic)", "\(p.isInput)"] }
        return parameters.map(signature) == other.parameters.map(signature)
    }

    var description: String {
        guard let name else { return "<closure>" }
        let labels = parameters.map { ($0.label ?? "_") + ":" }.joined()
        return "<func \(name)(\(labels))>"
    }

    var isBuiltin: Bool {
        if case .swish = body { false } else { true }
    }

    /// A body that is a single expression returns its value, as in Swift:
    /// a closure's, or a function's that says what it returns. A function
    /// without `->` returns nothing.
    var implicitReturn: Expr? {
        guard name == nil || returnType != nil, case .swish(let body) = body, body.statements.count == 1,
              case .chain(let chain) = body.statements[0], chain.links.isEmpty,
              case .expression(let expr) = chain.first else { return nil }
        return expr
    }
}
