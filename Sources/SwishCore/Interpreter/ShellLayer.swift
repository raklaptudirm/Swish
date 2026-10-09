import SwishKit

/// The process's variables, for `env`.
struct EnvironmentAccess {
    var get: (String) -> String?
    /// Every variable, by name.
    var all: () -> [(name: String, value: String)]
    /// Sets a variable, or removes it when the value is nil.
    var set: (String, String?) -> Void
}

/// The shell's constructs: commands, jobs and `$(…)`.
struct CommandAccess {
    /// Runs the body with what it writes to the output gathered up and
    /// returned, as `$(…)` does.
    var capture: (() throws -> Void) throws -> String
    /// Whether a program of that name could be run.
    var hasProgram: (String) -> Bool
    /// Runs a pipeline of commands, showing its result when asked, and gives
    /// the exit status.
    var run: (PipelineNode, _ display: Bool) throws -> Int32
    /// Starts a pipeline in the background, giving the job.
    var start: (PipelineNode, _ capture: Bool) throws -> Value
    /// The jobs there are, with their states current.
    var jobs: () -> [Value]
    /// `await`, on a job or (with no operand) the latest one; `throwing`
    /// for `try await`.
    var await: (_ job: Value?, _ throwing: Bool) throws -> Value
    /// `xs.select(…)`: a sequence method called on a list, whose `@input`
    /// the pipeline machinery feeds.
    var callSequenceMethod: (OverloadSet, _ items: [Value], [Argument]) throws -> Value
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
/// | `commands.run`, `start`, `capture` | grammar | the desugaring: the core never sees those nodes |
/// | `commands.hasProgram` | grammar | the shell's own name resolution |
struct ShellLayer {
    var environment: EnvironmentAccess
    var commands: CommandAccess
    /// Loads a plugin: `import Name from path`.
    var importPlugin: (_ name: String, _ path: String) throws -> Void
    /// What was entered before, oldest first.
    var history: () -> [String]
    /// The columns a table starts with for the shell's own types (`Job`,
    /// `Help`), which the core doesn't know by name.
    var columns: [String: [DisplayColumn]]
}

extension Interpreter {
    /// The environment, or a refusal where there is no shell layer.
    func environmentAccess() throws -> EnvironmentAccess {
        guard let layer = shellLayer else { throw RuntimeError("the environment isn't available here") }
        return layer.environment
    }

    /// Commands, jobs and `$(…)`, or a refusal where there is no shell layer.
    func commandAccess() throws -> CommandAccess {
        guard let layer = shellLayer else { throw RuntimeError("commands aren't available here") }
        return layer.commands
    }

    /// `import Name from path`, or a refusal where there is no shell layer.
    func importPlugin(_ name: String, from path: String) throws {
        guard let layer = shellLayer else { throw RuntimeError("plugins can't be imported here") }
        try layer.importPlugin(name, path)
    }

    /// What was entered before, for the library functions that ask.
    var historyEntries: [String] { shellLayer?.history() ?? [] }
}
