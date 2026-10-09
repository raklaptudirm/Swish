import Swiit
import SwishKit

extension Shell {
    /// `jobs`, the jobs in the background oldest first, and what `await` waits
    /// for (a `Job`, or with no operand the latest one).
    func installJobs() {
        interpreter.bind(computed: "jobs", type: .list(.named("Job"))) { [unowned self] in
            updateJobs() // So their states are current.
            return .list(jobs.map { .object($0) })
        }
        interpreter.awaiting = Awaiting(operand: .named("Job"), result: .output) { [unowned self] value, throwing in
            let job: Job
            if let value {
                guard case .object(let object as Job) = value else {
                    throw RuntimeError("await needs a Job, not \(value.typeName)")
                }
                job = object
            } else {
                guard let latest = jobs.last else { throw RuntimeError("there are no jobs to await") }
                job = latest
            }
            let output = try awaitJob(job)
            if throwing && !output.succeeded {
                throw RuntimeError.commandFailure("\(job.source) failed with status \(job.status)", status: job.status, output: output)
            }
            return .output(output)
        }
    }
}
