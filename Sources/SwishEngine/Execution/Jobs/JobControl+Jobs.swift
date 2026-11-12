import Foundation
import Swiit
import SwishLibrary

// The job table: putting a job in it, noticing what changed, and checking on the running ones.

extension JobControl {
    /// Puts a job in `jobs`, giving it the next free number.
    func adopt(_ job: Job) {
        guard job.id == 0 else { return }
        job.id = (jobs.map(\.id).max() ?? 0) + 1
        jobs.append(job)
    }

    /// What's changed with background jobs, for the notices before the next
    /// prompt. Finished jobs leave `jobs` once they've been reported.
    func notices(styled: Bool = false) -> [String] {
        updateJobs()
        var notices: [String] = []
        for job in jobs where job.state != .running && !job.reported {
            job.reported = true
            notices.append(
                job.state == .stopped
                    ? job.line(styled: styled)
                        + "  (waiting for the terminal: await it)".styled(DisplayStyle.dim, styled)
                    : job.line(styled: styled)
            )
        }
        jobs.removeAll { $0.state == .done }
        return notices
    }

    /// Checks on background jobs without waiting, noting which finished or
    /// stopped. Finished jobs stay in `jobs`, shown as done, until they're
    /// announced or awaited.
    func updateJobs() {
        for job in jobs where job.state == .running {
            if let task = job.task {
                if task.isFinished { job.finish() }
                continue
            }
            var stopped = false
            for pid in job.running {
                var raw: Int32 = 0
                guard waitpid(pid, &raw, WNOHANG | WUNTRACED) == pid else { continue }
                if WaitStatus(raw).stopped {
                    stopped = true
                    continue
                }
                job.running.removeAll { $0 == pid }
                if pid == job.lastPid {
                    job.status = Status(WaitStatus(raw))
                }
            }
            if job.running.isEmpty {
                job.finish()
            } else if stopped {
                job.state = .stopped
            }
        }
    }
}
