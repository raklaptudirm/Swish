import Foundation

extension Shell {
    /// `fg` and `bg` are only here to say what replaced them.
    static let builtinNames: Set = ["cd", "pwd", "exit", "fg", "bg", "which"]

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
