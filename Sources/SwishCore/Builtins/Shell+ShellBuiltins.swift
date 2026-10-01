import Foundation
import SwishKit

/// A builtin that isn't a function: it changes the shell itself, so it
/// can't be a program, and it takes words, as a program does. One table
/// says what each is, how it's used and what it does, for running it,
/// `which`, `help`, completion and highlighting.
struct ShellBuiltin: Sendable {
    enum Action: Sendable {
        /// Runs in the shell, as `cd` and `umask` do.
        case run(@Sendable (Shell, [String]) -> Int32)
        /// Becomes a program, as `run` becomes Swish started on a task file.
        case program(@Sendable (Shell, [String]) throws -> [String])
        /// Other shells' builtin, here only to say what Swish has instead.
        /// Some are programs in /usr/bin too, which can't change the shell
        /// they're run from, so they'd seem to work and do nothing.
        case notSwish(instead: String)
    }

    let name: String
    let usage: String
    let summary: String
    let action: Action

    /// Whether it does something, rather than say what does.
    var works: Bool {
        if case .notSwish = action { false } else { true }
    }
}

extension Shell {
    static let shellBuiltins: [String: ShellBuiltin] = Dictionary(
        uniqueKeysWithValues: (working + notSwish).map { ($0.name, $0) }
    )

    /// They change the shell itself, so they read their words as other
    /// shells' do, before Swish's binder; step 4 of the foundations makes
    /// them Swift functions with flags and help like the rest.
    private static let working: [ShellBuiltin] = [
        ShellBuiltin(name: "cd", usage: "cd [<dir> | -]",
                     summary: "Changes the working directory: to <dir>, back to the previous one (-), or home.",
                     action: .run { $0.cd($1) }),
        ShellBuiltin(name: "exec", usage: "exec <program> [<argument>...]", summary: "Runs a program in the shell's place.",
                     action: .run { $0.exec($1) }),
        ShellBuiltin(name: "exit", usage: "exit [<status>]", summary: "Leaves the shell, with <status> or the last command's.",
                     action: .run { $0.exitShell($1) }),
        ShellBuiltin(name: "run", usage: "run [<task> [<argument>...]]",
                     summary: "Runs a task: a function in the nearest Tasks.swish, here or in a parent directory, in a Swish of its own. Alone, lists the tasks.",
                     action: .program { try $0.taskCommand($1) }),
        ShellBuiltin(name: "source", usage: "source <file> [<argument>...]",
                     summary: "Runs a Swish file in this shell, so what it declares stays declared.",
                     action: .run { $0.source($1) }),
        ShellBuiltin(name: "ulimit", usage: "ulimit [-a] [-S|-H] [\(ResourceLimit.all.map { "-\($0.flag)" }.joined(separator: "|"))] [<limit>|unlimited]",
                     summary: "Shows or sets a resource limit for the shell and what it runs: file size (-f) unless another is named.",
                     action: .run { $0.ulimit($1) }),
        ShellBuiltin(name: "umask", usage: "umask [<mask>]",
                     summary: "Shows or sets, in octal, the permissions new files are made without.",
                     action: .run { $0.umask($1) }),
        ShellBuiltin(name: "which", usage: "which <name>...",
                     summary: "Says what each name runs: a function, a shell builtin or a program.",
                     action: .run { $0.which($1) }),
    ]

    private static let notSwish: [ShellBuiltin] = [
        ("fg", "`await` brings back the most recent job, `await jobs[n]` another"),
        ("bg", "`jobs.last.resume()` carries a stopped job on in the background"),
        ("alias", "declare a function, as in `func ll() { ls -la }`"),
        ("unalias", "functions are aliases; a new `func` with the same name replaces one"),
        ("wait", "`await` waits for the most recent job, `await jobs[n]` for another"),
        ("read", "`readLine()` gives a line of input, or nil at its end"),
        ("type", "`which name` says what a name runs"),
        ("command", "`^name` runs the program, skipping functions of that name"),
        ("hash", "programs are looked up on PATH each time"),
        ("getopts", "a function's parameters are its options; see `help`"),
        ("fc", "^R searches your history, and `history()` lists it"),
        ("export", "`env.NAME = value` sets an environment variable for the programs you run"),
        ("unset", "`env.NAME = nil` removes an environment variable"),
        ("set", "`try!` stops a script when a command fails, as set -e would"),
        ("trap", "`defer { … }` runs when a script ends, including by ^C, kill or hangup"),
        ("eval", "`source file` runs a file in this shell"),
        ("declare", "`let` and `var` declare variables"),
        ("local", "a `var` in a function is its own"),
        ("readonly", "`let` declares a constant"),
        ("shift", "`args` is a list: `args.dropFirst()`"),
    ].map { (name: String, instead: String) in ShellBuiltin(name: name, usage: "", summary: "", action: .notSwish(instead: instead)) }
}

extension Shell {
    /// Runs `argv` as a builtin that runs in the shell, or returns nil if
    /// it isn't one.
    func runBuiltin(_ argv: [String]) -> Int32? {
        switch Shell.shellBuiltins[argv[0]]?.action {
        case .run(let run)?:
            return run(self, Array(argv.dropFirst()))
        case .notSwish(let instead)?:
            report("\(argv[0]) isn't Swish: \(instead)")
            return 2
        case .program?, nil:
            return nil
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
            } else if let builtin = Shell.shellBuiltins[name] {
                if case .notSwish(let instead) = builtin.action {
                    writeAll(stdoutFD, "\(name): not Swish; \(instead)\n")
                } else {
                    writeAll(stdoutFD, "\(name): shell builtin\n")
                }
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
