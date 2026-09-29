import Foundation

extension Shell {
    /// `fg` and `bg` are only here to say what replaced them. `run` becomes
    /// a program, Swish itself, when its pipeline is made.
    static let builtinNames: Set = ["cd", "pwd", "exit", "fg", "bg", "which", "run"]

    /// The name of the file `run` finds its tasks in.
    static let taskFileName = "Tasks.swish"

    /// The Swish executable, which `run` starts for a task file.
    nonisolated(unsafe) static var executablePath: String? = Bundle.main.executablePath

    /// `run task args…` as the program that runs it: this Swish, told to run
    /// `task` from the nearest Tasks.swish, here or in a parent directory.
    /// Its own process, so a task's `cd` or variables don't touch the shell.
    func taskCommand(_ arguments: [String], from start: String = FileManager.default.currentDirectoryPath) throws -> [String] {
        var directory = URL(fileURLWithPath: start).standardizedFileURL
        while true {
            let file = directory.appendingPathComponent(Shell.taskFileName).path
            if FileManager.default.fileExists(atPath: file) {
                guard let swish = Shell.executablePath else { throw RuntimeError("run: can't find the Swish executable") }
                return [swish, "--tasks", file] + arguments
            }
            let parent = directory.deletingLastPathComponent()
            guard parent.path != directory.path else {
                throw RuntimeError("run: no \(Shell.taskFileName) here or in a parent directory")
            }
            directory = parent
        }
    }

    /// Runs `argv` as a builtin, or returns nil if it isn't one.
    func runBuiltin(_ argv: [String]) -> Int32? {
        let args = Array(argv.dropFirst())
        switch argv[0] {
        case "cd": return cd(args)
        case "pwd": return pwd(args)
        case "exit": return exitShell(args)
        case "fg":
            report("fg isn't Swish: `await` brings back the most recent job, `await jobs[n]` another")
            return 2
        case "bg":
            report("bg isn't Swish: `jobs.last.resume()` carries a stopped job on in the background")
            return 2
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
        if !jobs.isEmpty && !warnedAboutJobs {
            warnedAboutJobs = true
            report("there are jobs in the background (see `jobs`); exit again to leave anyway")
            return 1
        }
        Foundation.exit(code)
    }

    /// What each name runs in command mode, in lookup order: after a `|`,
    /// sequence methods; functions, builtins, then programs on PATH.
    private func which(_ args: [String]) -> Int32 {
        var status: Int32 = 0
        for name in args {
            if let methods = sequenceMethods[name] {
                for method in methods.candidates {
                    writeAll(stdoutFD, "\(name): sequence method \(method.signature)\n")
                }
            } else if let functions = commandFunctions(named: name) {
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
