import Swiit
import Foundation
import SystemPackage

extension Shell {
    /// Runs a script file. A `try!` that fails stops it; any other error
    /// only abandons the statement it's in.
    ///
    /// `arguments` are the script's `args`. If the script declares `main`,
    /// it's then called with them as its command line, so a script gets
    /// flags, `--help` and completion from `main`'s signature.
    public func runScript(at path: String, arguments: [String] = []) -> Int32 {
        // ^C, kill and hangup stop the script at the next statement, so its
        // defers run; then it ends by the signal (see `endBySignal`).
        catchInterrupts([SIGINT, SIGTERM, SIGHUP])
        return runFile(at: path, arguments: arguments) { [self] reading in
            guard let main = topLevelFunction("main", in: reading) else { return }
            // `main` stands for the script, so its help and errors use the script's name.
            callAsCommand(main, named: FilePath(path).lastComponent?.string ?? path, arguments)
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
    /// Reads, checks and runs a file's top level, then `finish`, unless a
    /// `try!` stopped it. A top-level `defer` runs when it's all over.
    func runFile(at path: String, arguments: [String], then finish: @escaping (Reading) -> Void) -> Int32 {
        guard let data = FileManager.default.contents(atPath: path) else {
            report("\(path): \(errorMessage(errno).lowercased())")
            return 127
        }
        interpreter["args"] = Value(arguments.map { Value($0) })
        interpreter.file = URL(fileURLWithPath: path).standardizedFileURL.path
        scriptDirectory = URL(fileURLWithPath: path).standardizedFileURL.deletingLastPathComponent().path
        // Read and checked whole, so doc comments reach their functions and a mistake anywhere stops the script before any
        // of it runs; then run a statement at a time, so a runtime error only abandons its own.
        var source = String(decoding: data, as: UTF8.self)
        // `#!/usr/bin/env swish`, so it runs as a program; the line stays,
        // blank, so line numbers do too.
        if source.hasPrefix("#!") { source = String(source.drop { $0 != "\n" }) }
        diagnosticSource = (source, path)
        let reading: Reading
        switch prepare(source) {
        case .failure(let diagnostic):
            reportReadingFailure(diagnostic, file: path)
            return lastStatus
        case .success(let read):
            reading = read
        }
        // What the script is for (`main`, a task) runs after its statements, and before its top-level defers.
        runReportingErrors(reading, then: { [unowned self] in if !scriptStopped { finish(reading) } })
        return lastStatus
    }

    /// A function the file declared at its top level.
    func topLevelFunction(_ name: String, in reading: Reading) -> Callee? {
        let functions = reading.declared.symbols.filter { $0.name == name && $0.function != nil }
        return functions.isEmpty ? nil : Callee(name: name, overloads: functions, receiver: nil, marks: scriptMarks)
    }

    /// Calls a script's function with command-line `arguments`, under `name`
    /// for its help and errors.
    func callAsCommand(_ callee: Callee, named name: String, _ arguments: [String]) {
        var callee = callee
        callee.shownName = name
        stoppedBySignal = nil
        do {
            lastStatus = try callCommand(callee, arguments.map(CommandArgument.text), display: true)
        } catch let error as ScriptError {
            if !error.isReported { report("error: \(error)") }
            lastStatus = error.status
        } catch {
            report("error: \(error)")
            lastStatus = 1
        }
    }
}
