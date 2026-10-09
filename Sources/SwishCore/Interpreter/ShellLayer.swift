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
}
