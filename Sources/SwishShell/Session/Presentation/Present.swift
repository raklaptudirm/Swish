@_spi(Layer) import Swiit

extension Shell {
    /// What the prompt does with an expression statement's value: shows it,
    /// unless Swift would discard it or it is an `await` whose job already
    /// wrote to the terminal.
    func present(_ value: Value, from expression: Expr, discarded: Bool) {
        let awaitedToTerminal = expression.isAwait && value.showsNothing
        // A command's `Status` is recorded as the status, not shown.
        if value.kind == .structure, value.typeName == "Status" { return }
        guard !discarded, !awaitedToTerminal else { return }
        show(value, debug: true)
    }
}
