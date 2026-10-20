import Swiit

extension Shell {
    /// `jobs`, the jobs in the background oldest first, and what `await` waits
    /// for (a `Job`, or with no operand the latest one).
    func installJobs() {
        interpreter.register(computed: "jobs", type: .list(.named("Job"))) { [unowned self] in
            updateJobs() // So their states are current.
            return Value(jobs.map { Value($0) })
        }
        interpreter.register(Awaiting(
            operand: .named("Job"), result: .named("Output"), isHandle: { $0.cast(to: Job.self) != nil },
            // `async f()`'s job holds what `f` gives, which awaiting it gives.
            resultOf: { if case .named("Job", let held) = $0, held.count == 1 { held[0] } else { nil } }
        ) { [unowned self] value, throwing in
            let job: Job
            if let value {
                guard let object = value.cast(to: Job.self) else {
                    throw RuntimeError("await needs a Job, not \(value.typeName)")
                }
                job = object
            } else {
                guard let latest = jobs.last else { throw RuntimeError("there are no jobs to await") }
                job = latest
            }
            // A task's value, unless it was `async $(…)`.
            if let task = job.task, !job.givesOutput {
                _ = try awaitJob(job)
                if case .success(let value)? = task.result { return value }
                return .null
            }
            let output = try awaitJob(job)
            if throwing && !output.succeeded {
                throw RuntimeError.commandFailure("\(job.source) failed with status \(job.status)", status: job.status, output: output)
            }
            return .output(output)
        })
    }
}
