import Foundation
import SwishEngine

let commandLine = Array(CommandLine.arguments.dropFirst())

// A login shell, as a terminal starts one (`-swish`), or as `swish --login` or `-l` asks.
let loginFlag = ["-l", "--login"].contains(commandLine.first ?? "")
let isLogin = CommandLine.arguments.first?.hasPrefix("-") == true || loginFlag
let arguments = loginFlag ? Array(commandLine.dropFirst()) : commandLine

// Recursion in Swish code recurses in the interpreter too, so run it on a
// thread with a far larger stack than the main thread's 8 MB. Only the pages
// actually used are committed.
let interpreter = Thread {
    let shell = Shell()
    let prompt = InteractivePrompt(shell: shell)
    prompt.declareScriptFunctions()
    TaskRunner(shell: shell).registerRunBuiltin()
    if isLogin { setUpLogin(shell) }
    switch arguments.first {
    case nil:
        exit(prompt.run())
    // A script's top level is a scope: its tasks are cancelled and waited for at its end.
    case "-c" where arguments.count == 2:
        let status = shell.execute(arguments[1])
        shell.cancelAndJoinTasks()
        exit(status)
    // What `run` starts: a task file, and the task to run from it.
    case "--tasks" where arguments.count >= 2:
        let status = TaskRunner(shell: shell)
            .run(
                at: arguments[1],
                task: arguments.dropFirst(2).first,
                arguments: Array(arguments.dropFirst(3))
            )
        shell.cancelAndJoinTasks()
        shell.endBySignal()
        exit(status)
    case let path? where !path.hasPrefix("-"):
        let status = shell.runScript(at: path, arguments: Array(arguments.dropFirst()))
        shell.cancelAndJoinTasks()
        shell.endBySignal()
        exit(status)
    default:
        FileHandle.standardError.write(
            Data(
                "usage: swish [-l] [-c command | script [arguments…] | --tasks file [task [arguments…]]]\n"
                    .utf8
            )
        )
        exit(2)
    }
}
interpreter.stackSize = 1 << 30
interpreter.start()
dispatchMain()
