import Foundation

extension Shell {
    /// The builtins that do something: they change the shell itself, so
    /// they can't be programs. `run` becomes a program, Swish itself, when
    /// its pipeline is made.
    static let workingBuiltins: Set = ["cd", "exit", "which", "run", "umask", "ulimit", "exec", "source"]

    /// Other shells' builtins, here only to say what Swish has instead. Some
    /// are programs in /usr/bin too, which can't change the shell they're
    /// run from, so they'd seem to work and do nothing.
    static let notSwish: [String: String] = [
        "fg": "`await` brings back the most recent job, `await jobs[n]` another",
        "bg": "`jobs.last.resume()` carries a stopped job on in the background",
        "alias": "declare a function, as in `func ll() { ls -la }`",
        "unalias": "functions are aliases; a new `func` with the same name replaces one",
        "wait": "`await` waits for the most recent job, `await jobs[n]` for another",
        "read": "`readLine()` gives a line of input, or nil at its end",
        "type": "`which name` says what a name runs",
        "command": "`^name` runs the program, skipping functions of that name",
        "hash": "programs are looked up on PATH each time",
        "getopts": "a function's parameters are its options; see `help`",
        "fc": "^R searches your history, and `history()` lists it",
        "export": "`env.NAME = value` sets an environment variable for the programs you run",
        "unset": "`env.NAME = nil` removes an environment variable",
        "set": "`try!` stops a script when a command fails, as set -e would",
        "trap": "`defer { … }` runs when a script ends, including by ^C, kill or hangup",
        "eval": "`source file` runs a file in this shell",
        "declare": "`let` and `var` declare variables",
        "local": "a `var` in a function is its own",
        "readonly": "`let` declares a constant",
        "shift": "`args` is a list: `args.dropFirst()`",
    ]

    static let builtinNames = workingBuiltins.union(notSwish.keys)

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
        case "exit": return exitShell(args)
        case "which": return which(args)
        case "umask": return umask(args)
        case "ulimit": return ulimit(args)
        case "exec": return exec(args)
        case "source": return source(args)
        default:
            guard let instead = Shell.notSwish[argv[0]] else { return nil }
            report("\(argv[0]) isn't Swish: \(instead)")
            return 2
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

    /// `umask`: the mask, in octal; `umask 077`: sets it, for what the shell
    /// and the programs it runs create from then on.
    private func umask(_ args: [String]) -> Int32 {
        guard let mask = args.first else {
            writeAll(stdoutFD, String(format: "%04o", Int(fileCreationMask)) + "\n")
            return 0
        }
        guard args.count == 1, let value = mode_t(mask, radix: 8), value <= 0o777 else {
            report("umask: give the mask in octal, as in 022")
            return 2
        }
        fileCreationMask = value
        return 0
    }

    /// `ulimit -n`: a limit (`-f`, file size, if none is named); `ulimit -n
    /// 4096` or `unlimited` sets it; `-a` shows them all. `-S` and `-H` pick
    /// the soft or hard limit; setting without either sets both.
    private func ulimit(_ args: [String]) -> Int32 {
        var soft = false, hard = false, all = false
        var limit: ResourceLimit?
        var value: String?
        for arg in args {
            if arg.hasPrefix("-") && arg.count > 1 {
                for flag in arg.dropFirst() {
                    switch flag {
                    case "S": soft = true
                    case "H": hard = true
                    case "a": all = true
                    default:
                        guard let found = ResourceLimit.all.first(where: { $0.flag == flag }) else {
                            report("ulimit: unknown limit -\(flag); -a lists them")
                            return 2
                        }
                        limit = found
                    }
                }
            } else if value == nil {
                value = arg
            } else {
                report("ulimit: too many arguments")
                return 2
            }
        }
        func shown(_ units: UInt64?) -> String { units.map(String.init) ?? "unlimited" }
        do throws(Errno) {
            if all {
                let width = ResourceLimit.all.map(\.name.count).max()!
                for limit in ResourceLimit.all {
                    let name = limit.name.padding(toLength: width, withPad: " ", startingAt: 0)
                    writeAll(stdoutFD, "\(name)  (-\(limit.flag))  \(shown(try limit.current(hard: hard)))\n")
                }
                return 0
            }
            let chosen = limit ?? ResourceLimit.all.first { $0.flag == "f" }!
            guard let value else {
                writeAll(stdoutFD, shown(try chosen.current(hard: hard)) + "\n")
                return 0
            }
            let units: UInt64?
            if value == "unlimited" {
                units = nil
            } else if let number = UInt64(value) {
                units = number
            } else {
                report("ulimit: \(value): not a number or `unlimited`")
                return 2
            }
            try chosen.set(units, soft: soft || !hard, hard: hard || !soft)
            return 0
        } catch {
            report("ulimit: \(errorMessage(error.code).lowercased())")
            return 1
        }
    }

    /// `exec program args…`: the program takes the shell's place.
    private func exec(_ args: [String]) -> Int32 {
        guard let name = args.first else {
            report("exec: give a program to run in the shell's place")
            return 2
        }
        guard let path = findExecutable(name) else {
            report("exec: \(name): command not found")
            return 127
        }
        if interactive { tcsetattr(terminal, TCSANOW, &shellModes) }
        let error = replaceProcess(with: path, args)
        report("exec: \(name): \(errorMessage(error.code).lowercased())")
        return 126
    }

    /// `source file args…`: runs a Swish file in this shell, so what it
    /// declares stays declared. A relative path starts from the script's
    /// directory, or the working directory at the prompt.
    private func source(_ args: [String]) -> Int32 {
        guard let path = args.first else {
            report("source: give a Swish file to run")
            return 2
        }
        let resolved = path.hasPrefix("/") ? path : (scriptDirectory ?? FileManager.default.currentDirectoryPath) + "/" + path
        return sourceFile(resolved, arguments: Array(args.dropFirst()))
    }

    /// Runs a file's top level in this shell, then puts back what running a
    /// file changes: `args`, `#filePath`, and whether a script stopped.
    func sourceFile(_ path: String, arguments: [String]) -> Int32 {
        let saved = (scriptPath, scriptDirectory, scopes[0].bindings["args"], scriptStopped)
        defer {
            (scriptPath, scriptDirectory) = (saved.0, saved.1)
            scopes[0].bindings["args"] = saved.2
            scriptStopped = saved.3
        }
        return runFile(at: path, arguments: arguments) { _ in }
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
            } else if Shell.workingBuiltins.contains(name) {
                writeAll(stdoutFD, "\(name): shell builtin\n")
            } else if let instead = Shell.notSwish[name] {
                writeAll(stdoutFD, "\(name): not Swish; \(instead)\n")
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
