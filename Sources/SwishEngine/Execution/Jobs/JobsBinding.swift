import Swiit

extension Shell {
    /// `jobs`, the jobs in the background oldest first.
    func installJobs() {
        interpreter.register(computed: "jobs", type: .list(.named(Job.id, [.named(Output.id)]))) {
            [unowned self] in
            jobControl.updateJobs()  // So their states are current.
            return Value(jobControl.jobs.map { Value($0) })
        }
    }
}

extension Shell {
    /// What `await job` is, written out by the front end as `await awaited(job)` (Resources/Prelude.swift):
    /// the latest job, for a bare `await`, and waiting for one.
    var jobBodies: [String: @Sendable ([String: Value]) throws -> Value] {
        [
            "latestJob": { [unowned self] _ in
                guard let latest = jobControl.jobs.last else {
                    throw RuntimeError("there are no jobs to await")
                }
                return Value(latest)
            },
            "waitForJob": { [unowned self] arguments in
                guard let job = arguments["job"]?.casting(to: Job.self) else {
                    throw RuntimeError(
                        "await needs a Job, not \(arguments["job"]?.typeName ?? "nothing")"
                    )
                }
                let throwing = arguments["throwing"]?.casting(to: Bool.self) ?? false
                // A task's value, unless it was `async $(…)`.
                if let task = job.task, !job.givesOutput {
                    _ = try awaitJob(job)
                    if case .success(let value)? = task.result { return value }
                    return .nothing
                }
                let output = try awaitJob(job)
                if throwing && !output.status.succeeded {
                    throw RuntimeError.commandFailure(
                        "\(job.source) failed with status \(output.status.number)",
                        output: output,
                        shell: self
                    )
                }
                return .output(output)
            },
        ]
    }
}
