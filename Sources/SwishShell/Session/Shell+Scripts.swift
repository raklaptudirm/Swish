import Foundation
import Swiit
import SystemPackage

extension Shell {
    /// Runs a script file. A `try!` that fails stops it; any other error
    /// only abandons the statement it's in.
    ///
    /// `arguments` are the script's `args`. If the script declares `main`,
    /// it's then called with them as its command line, so a script gets
    /// flags, `--help` and completion from `main`'s signature.
    public func runScript(at path: String, arguments: [String] = []) -> Int32 {
        runScript(at: path, arguments: arguments) { file in
            // `main` stands for the script, so its help and errors use the script's name.
            file.call(
                "main",
                as: FilePath(path).lastComponent?.string ?? path,
                arguments: arguments
            )
        }
    }

    /// Runs a script's top level, then `finish` with what it declared, unless a `try!` stopped it:
    /// for a client that runs a function of the script, as a task runner does.
    public func runScript(
        at path: String,
        arguments: [String],
        then finish: @escaping (ScriptFile) -> Void
    ) -> Int32 {
        // ^C, kill and hangup stop the script at the next statement, so its
        // defers run; then it ends by the signal (see `endBySignal`).
        catchInterrupts([SIGINT, SIGTERM, SIGHUP])
        return runFile(at: path, arguments: arguments) { [self] reading in
            finish(ScriptFile(shell: self, reading: reading))
        }
    }

    /// After a script stopped by a signal has run its defers: ends the
    /// process by that signal, as the script would have without them, so
    /// whatever started it sees how it ended.
    public func endBySignal() {
        guard let ending = endingSignal else { return }
        signal(ending, SIG_DFL)
        kill(getpid(), ending)
    }
}

extension Shell {
    /// A script that has run its top level: what it declared, and a way to run a function of it as
    /// a command.
    public struct ScriptFile {
        unowned let shell: Shell
        let reading: Shell.Reading

        /// The functions the script declared at its top level.
        public var functions: [Symbol] { reading.declared.symbols.filter { $0.function != nil } }

        /// Runs the function `name` the script declared as a command with `arguments`, under
        /// `shownName` for its help and errors. Says whether there is one.
        @discardableResult
        public func call(_ name: String, as shownName: String, arguments: [String]) -> Bool {
            guard let function = shell.topLevelFunction(name, in: reading) else { return false }
            shell.callAsCommand(function, named: shownName, arguments)
            return true
        }
    }

    /// Reads, checks and runs a file's top level, then `finish`, unless a
    /// `try!` stopped it. A top-level `defer` runs when it's all over.
    func runFile(
        at path: String,
        arguments: [String],
        then finish: @escaping (Reading) -> Void
    ) -> Int32 {
        guard let data = FileManager.default.contents(atPath: path) else {
            report("\(path): \(errorMessage(errno).lowercased())")
            return 127
        }
        interpreter["args"] = Value(arguments.map { Value($0) })
        interpreter.file = URL(fileURLWithPath: path).standardizedFileURL.path
        scriptDirectory =
            URL(fileURLWithPath: path).standardizedFileURL.deletingLastPathComponent().path
        // Read and checked whole, so doc comments reach their functions and a mistake anywhere
        // stops the script before any of it runs; then run a statement at a time, so a runtime
        // error only abandons its own.
        var source = String(decoding: data, as: UTF8.self)
        // `#!/usr/bin/env swish`, so it runs as a program; the line stays,
        // blank, so line numbers do too.
        if source.hasPrefix("#!") { source = String(source.drop { $0 != "\n" }) }
        diagnosticSource = (source, path)
        let reading: Reading
        switch prepare(source) {
        case .failure(let diagnostic):
            reportReadingFailure(diagnostic, file: path)
            return lastStatus.number
        case .success(let read):
            reading = read
        }
        // What the script is for (`main`, a task) runs after its statements, and before its
        // top-level defers.
        runReportingErrors(
            reading,
            then: { [unowned self] in if !scriptStopped { finish(reading) } }
        )
        return lastStatus.number
    }

    /// A function the file declared at its top level.
    func topLevelFunction(_ name: String, in reading: Reading) -> Callee? {
        let functions = reading.declared.symbols.filter { $0.name == name && $0.function != nil }
        return functions.isEmpty
            ? nil : Callee(name: name, overloads: functions, receiver: nil, marks: scriptMarks)
    }

    /// Calls a script's function with command-line `arguments`, under `name`
    /// for its help and errors.
    func callAsCommand(_ callee: Callee, named name: String, _ arguments: [String]) {
        var callee = callee
        callee.shownName = name
        stoppedBySignal = nil
        do {
            lastStatus = try callCommand(callee, arguments.map(CommandArgument.text), display: true)
        } catch let error as Diagnostic {
            report("error: \(error)")
            lastStatus = .exited(error.status)
        } catch {
            report("error: \(error)")
            lastStatus = .exited(1)
        }
    }
}
