import Foundation
import SwishCore

let shell = Shell()
let arguments = Array(CommandLine.arguments.dropFirst())

switch arguments.first {
case nil:
    exit(shell.runInteractive())
case "-c" where arguments.count == 2:
    exit(shell.execute(arguments[1]))
default:
    FileHandle.standardError.write(Data("usage: swish [-c command]\n".utf8))
    exit(2)
}
