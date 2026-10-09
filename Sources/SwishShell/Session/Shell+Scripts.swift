import Swiit
import Foundation
import SwishKit
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
        return runFile(at: path, arguments: arguments) { _ in
            guard let main = topLevelFunction("main") else { return }
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
    func runFile(at path: String, arguments: [String], then finish: (Program) -> Void) -> Int32 {
        guard let data = FileManager.default.contents(atPath: path) else {
            interpreter.report("\(path): \(errorMessage(errno).lowercased())")
            return 127
        }
        interpreter.scopes[0].bindings["args"] = Binding(value: .list(arguments.map(Value.string)), mutable: false)
        interpreter.file = URL(fileURLWithPath: path).standardizedFileURL.path
        scriptDirectory = URL(fileURLWithPath: path).standardizedFileURL.deletingLastPathComponent().path
        // Parsed whole, so doc comments reach their functions and a syntax
        // error anywhere stops the script before any of it runs; then run a
        // statement at a time, so a runtime error only abandons its own.
        let program: Program
        var source = String(decoding: data, as: UTF8.self)
        // `#!/usr/bin/env swish`, so it runs as a program; the line stays,
        // blank, so line numbers do too.
        if source.hasPrefix("#!") { source = String(source.drop { $0 != "\n" }) }
        switch interpreter.parse(source) {
        case .failure(let error):
            interpreter.report("\(path): syntax error: \(error)")
            return 2
        case .success(let parsed):
            program = parsed
        }
        // Checked whole too: a type error anywhere runs none of it.
        guard let program = typeCheck(program, file: path) else { return lastStatus }
        var deferred: [Program] = []
        defer { interpreter.runDeferred(deferred) }
        // Functions and types first, so any line can use them.
        runReportingErrors(Program(statements: program.statements.filter {
            if case .function = $0 { return true }
            return $0.declaresType
        }))
        for statement in program.statements {
            if case .deferBlock(let body) = statement {
                deferred.append(body)
                continue
            }
            if statement.declaresType { continue }
            runReportingErrors(Program(statements: [statement]))
            if scriptStopped { return lastStatus }
        }
        finish(program)
        return lastStatus
    }

    /// A function the file declared at its top level.
    func topLevelFunction(_ name: String) -> OverloadSet? {
        guard let binding = interpreter.scopes[1].bindings[name], binding.isFunction,
              case .function(let set as OverloadSet) = binding.value else { return nil }
        return set
    }

    /// Calls a script's function with command-line `arguments`, under `name`
    /// for its help and errors.
    func callAsCommand(_ set: OverloadSet, named name: String, _ arguments: [String]) {
        let command = OverloadSet(name: name, candidates: set.candidates.map {
            Function(name: name, parameters: $0.parameters, returnType: $0.returnType, body: $0.body,
                     captured: $0.captured, documentation: $0.documentation)
        })
        do {
            lastStatus = try callCommand(command, arguments.map(CommandArgument.text), display: true)
        } catch let interrupt as Interrupted {
            lastStatus = 128 + interrupt.signal
            endingSignal = interrupt.signal
        } catch let fatal as FatalError {
            interpreter.report("error: \(fatal.error)")
            lastStatus = fatal.error.status
        } catch let error as RuntimeError {
            interpreter.report("error: \(error)")
            lastStatus = error.status
        } catch is AlreadyReported {
            lastStatus = 1
        } catch {
            interpreter.report("error: \(error)")
            lastStatus = 1
        }
    }
}
