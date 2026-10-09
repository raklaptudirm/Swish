import SwishKit

/// The process's variables, for `env`.
package struct EnvironmentAccess {
    package var get: (String) -> String?
    /// Every variable, by name.
    package var all: () -> [(name: String, value: String)]
    /// Sets a variable, or removes it when the value is nil.
    package var set: (String, String?) -> Void

    package init(get: @escaping (String) -> String?, all: @escaping () -> [(name: String, value: String)], set: @escaping (String, String?) -> Void) {
        self.get = get
        self.all = all
        self.set = set
    }
}

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
/// | `environment` | vocabulary | `env` as a registered object with dynamic members |
/// | `jobs` | vocabulary | a registered global |
/// | `commands.jobs`, `await` | vocabulary | `Job` as a registered type, `jobs` a global |
/// | `commands.callSequenceMethod` | grammar | the desugaring |
package struct ShellLayer {
    package var environment: EnvironmentAccess
    package var commands: CommandAccess
    /// Loads a plugin: `import Name from path`.
    package var importPlugin: (_ name: String, _ path: String) throws -> Void
    /// What was entered before, oldest first.
    package var history: () -> [String]
    /// The columns a table starts with for the shell's own types (`Job`,
    /// `Help`), which the core doesn't know by name.
    package var columns: [String: [DisplayColumn]]

    package init(environment: EnvironmentAccess, commands: CommandAccess, importPlugin: @escaping (_ name: String, _ path: String) throws -> Void, history: @escaping () -> [String], columns: [String: [DisplayColumn]]) {
        self.environment = environment
        self.commands = commands
        self.importPlugin = importPlugin
        self.history = history
        self.columns = columns
    }
}

extension Interpreter {
    /// The environment, or a refusal where there is no shell layer.
    package func environmentAccess() throws -> EnvironmentAccess {
        guard let layer = shellLayer else { throw RuntimeError("the environment isn't available here") }
        return layer.environment
    }

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
