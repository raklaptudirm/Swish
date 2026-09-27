import Foundation

extension Shell {
    static let builtinNames: Set = ["cd", "pwd", "exit", "fg", "jobs", "which"]

    /// Runs `argv` as a builtin, or returns nil if it isn't one.
    func runBuiltin(_ argv: [String]) -> Int32? {
        let args = Array(argv.dropFirst())
        switch argv[0] {
        case "cd": return cd(args)
        case "pwd": return pwd(args)
        case "exit": return exitShell(args)
        case "fg": return fg(args)
        case "jobs": return jobs(args)
        case "which": return which(args)
        default: return nil
        }
    }

    private func cd(_ args: [String]) -> Int32 {
        let target: String
        switch args.count {
        case 0:
            guard let home = env("HOME") else {
                report("cd: HOME not set")
                return 1
            }
            target = home
        case 1 where args[0] == "-":
            guard let previous = env("OLDPWD") else {
                report("cd: OLDPWD not set")
                return 1
            }
            target = previous
            writeAll(stdoutFD, previous + "\n")
        case 1:
            target = args[0]
        default:
            report("cd: too many arguments")
            return 1
        }

        let previous = FileManager.default.currentDirectoryPath
        guard chdir(target) == 0 else {
            report("cd: \(target): \(errorMessage(errno).lowercased())")
            return 1
        }
        setenv("OLDPWD", previous, 1)
        setenv("PWD", FileManager.default.currentDirectoryPath, 1)
        return 0
    }

    private func pwd(_ args: [String]) -> Int32 {
        writeAll(stdoutFD, FileManager.default.currentDirectoryPath + "\n")
        return 0
    }

    private func exitShell(_ args: [String]) -> Int32 {
        var code = lastStatus
        if let arg = args.first {
            guard let parsed = Int32(arg) else {
                report("exit: \(arg): numeric argument required")
                return 2
            }
            code = parsed
        }
        if !stoppedJobs.isEmpty && !warnedAboutStoppedJobs {
            warnedAboutStoppedJobs = true
            report("there are stopped jobs; exit again to leave anyway")
            return 1
        }
        Foundation.exit(code)
    }

    private func fg(_ args: [String]) -> Int32 {
        var index = stoppedJobs.count - 1
        if let arg = args.first {
            guard let number = Int(arg.hasPrefix("%") ? String(arg.dropFirst()) : arg),
                  stoppedJobs.indices.contains(number - 1) else {
                report("fg: \(arg): no such job")
                return 1
            }
            index = number - 1
        }
        guard index >= 0 else {
            report("fg: no current job")
            return 1
        }

        let job = stoppedJobs.remove(at: index)
        writeAll(stdoutFD, job.commandLine + "\n")
        if job.pgid > 0 {
            tcsetpgrp(terminal, job.pgid)
            kill(-job.pgid, SIGCONT)
        } else {
            job.running.forEach { kill($0, SIGCONT) }
        }
        return waitForeground(job)
    }

    private func jobs(_ args: [String]) -> Int32 {
        for (index, job) in stoppedJobs.enumerated() {
            writeAll(stdoutFD, "[\(index + 1)]  Stopped    \(job.commandLine)\n")
        }
        return 0
    }

    /// What each name runs in command mode, in lookup order: functions,
    /// builtins, then programs on PATH.
    private func which(_ args: [String]) -> Int32 {
        var status: Int32 = 0
        for name in args {
            if let functions = commandFunctions(named: name) {
                for function in functions.candidates {
                    let kind = function.isBuiltin ? "builtin function" : "function"
                    writeAll(stdoutFD, "\(name): \(kind) \(function.signature)\n")
                }
            } else if Shell.builtinNames.contains(name) {
                writeAll(stdoutFD, "\(name): shell builtin\n")
            } else if let path = findExecutable(name) {
                writeAll(stdoutFD, path + "\n")
            } else {
                report("which: \(name) not found")
                status = 1
            }
        }
        return status
    }
}
