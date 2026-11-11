import Swiit

extension Shell {
    /// What the prompt does with an expression statement's value: shows it, unless Swift would
    /// discard it (the function it called is `@discardableResult`) or it came from one marked
    /// `@alreadyShown`, which waited for a job that already wrote to the terminal.
    func present(_ value: Value, from callee: Symbol?) {
        let attributes = callee?.attributes ?? []
        let awaitedToTerminal = attributes.contains(named: "alreadyShown") && value.showsNothing
        // A command's `Status` is recorded as the status, not shown.
        if value.isInstance(of: preludeTypes.status) { return }
        guard !attributes.contains(named: "discardableResult"), !awaitedToTerminal else { return }
        show(value, debug: true)
    }
}
