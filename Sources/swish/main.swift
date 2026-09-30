import Foundation
import SwishCore

let arguments = Array(CommandLine.arguments.dropFirst())

// Recursion in Swish code recurses in the interpreter too, so run it on a
// thread with a far larger stack than the main thread's 8 MB. Only the pages
// actually used are committed.
let interpreter = Thread {
    let shell = Shell()
    switch arguments.first {
    case nil:
        exit(shell.runInteractive())
    case "-c" where arguments.count == 2:
        exit(shell.execute(arguments[1]))
    // What `run` starts: a task file, and the task to run from it.
    case "--tasks" where arguments.count >= 2:
        let status = shell.runTasks(at: arguments[1], task: arguments.dropFirst(2).first, arguments: Array(arguments.dropFirst(3)))
        shell.endBySignal()
        exit(status)
    case let path? where !path.hasPrefix("-"):
        let status = shell.runScript(at: path, arguments: Array(arguments.dropFirst()))
        shell.endBySignal()
        exit(status)
    default:
        FileHandle.standardError.write(Data("usage: swish [-c command | script [arguments…] | --tasks file [task [arguments…]]]\n".utf8))
        exit(2)
    }
}
interpreter.stackSize = 1 << 30
interpreter.start()
dispatchMain()
