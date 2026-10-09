import SwishKit

/// The shell's constructs the core still calls: jobs, `await` and the
/// sequence methods. (Running pipelines and `$(…)` are the shell's own nodes,
/// which reach their `Shell` through `Interpreter.owner`.)
package struct CommandAccess {
    /// The jobs there are, with their states current.
    package var jobs: () -> [Value]
    /// `await`, on a job or (with no operand) the latest one; `throwing`
    /// for `try await`.
    package var await: (_ job: Value?, _ throwing: Bool) throws -> Value
    /// `xs.select(…)`: a sequence method called on a list, whose `@input`
    /// the pipeline machinery feeds.
    package var callSequenceMethod: (OverloadSet, _ items: [Value], [Argument]) throws -> Value

    package init(jobs: @escaping () -> [Value], `await`: @escaping (_ job: Value?, _ throwing: Bool) throws -> Value, callSequenceMethod: @escaping (OverloadSet, _ items: [Value], [Argument]) throws -> Value) {
        self.jobs = jobs
        self.await = `await`
        self.callSequenceMethod = callSequenceMethod
    }
}

/// What the core still can't do without the shell. It is not part of the
/// host an embedder supplies: it is internal and temporary, a ledger of the
/// places the language layers depend on shell concepts, each with its exit
/// (Docs/Design/embedding.md). Without a layer, the core refuses them
/// plainly: `env` reads as empty and can't be set, commands and jobs don't run.
///
/// | Entry | Belongs to | Exit |
/// |---|---|---|
/// | `jobs` | vocabulary | a registered global |
/// | `commands.jobs`, `await` | vocabulary | `Job` as a registered type, `jobs` a global |
/// | `commands.callSequenceMethod` | grammar | the desugaring |
package struct ShellLayer {
    package var commands: CommandAccess
    /// Loads a plugin: `import Name from path`.
    package var importPlugin: (_ name: String, _ path: String) throws -> Void
    /// What was entered before, oldest first.
    package var history: () -> [String]
    /// The columns a table starts with for the shell's own types (`Job`,
    /// `Help`), which the core doesn't know by name.
    package var columns: [String: [DisplayColumn]]

    package init(commands: CommandAccess, importPlugin: @escaping (_ name: String, _ path: String) throws -> Void, history: @escaping () -> [String], columns: [String: [DisplayColumn]]) {
        self.commands = commands
        self.importPlugin = importPlugin
        self.history = history
        self.columns = columns
    }
}

extension Interpreter {
    /// Commands, jobs and `$(…)`, or a refusal where there is no shell layer.
    package func commandAccess() throws -> CommandAccess {
        guard let layer = shellLayer else { throw RuntimeError("commands aren't available here") }
        return layer.commands
    }

    /// `import Name from path`, or a refusal where there is no shell layer.
    package func importPlugin(_ name: String, from path: String) throws {
        guard let layer = shellLayer else { throw RuntimeError("plugins can't be imported here") }
        try layer.importPlugin(name, path)
    }

    /// What was entered before, for the library functions that ask.
    package var historyEntries: [String] { shellLayer?.history() ?? [] }
}
