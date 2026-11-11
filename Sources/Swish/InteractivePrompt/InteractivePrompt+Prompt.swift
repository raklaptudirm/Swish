import Foundation
import Swiit
import SwishShell

// The prompt: what the config's `prompt` function gives, or the default.

extension InteractivePrompt {
    /// The prompt: what the config's `prompt` function gives, or the default. One that fails is
    /// reported, and the default shown instead.
    func prompt() -> String {
        do {
            if let custom = try customPrompt() { return custom }
        } catch {
            shell.report("prompt: \(error)")
        }
        return defaultPrompt()
    }

    /// What the `prompt` function gives, or nil if there isn't one. It's `prompt() -> String`, or
    /// `prompt(status: Int) -> String` to be told how the last command exited.
    func customPrompt() throws -> String? {
        let overloads = shell.interpreter.globals(named: "prompt").compactMap { $0.function }
        guard !overloads.isEmpty else { return nil }

        let withStatus = overloads.first {
            $0.parameters.map(\.label) == ["status"] && $0.parameters[0].type == .int
        }
        guard let function = withStatus ?? overloads.first(where: { $0.parameters.isEmpty }),
            function.returns == .string
        else {
            throw PromptError(
                "declare it as `func prompt() -> String` or `func prompt(status: Int) -> String`"
            )
        }

        let arguments: [(label: String?, value: Value)] =
            withStatus != nil ? [("status", Value(Int(shell.lastStatus.number)))] : []
        // Drawing the prompt isn't a command.
        let value = try shell.keepingStatus {
            try shell.interpreter.call("prompt", arguments: arguments)
        }
        guard let text = value.casting(to: String.self) else {
            throw PromptError("it gave \(shell.interpreter.scriptType(of: value)), not a String")
        }
        return text
    }

    private func defaultPrompt() -> String {
        let directory = InteractivePrompt.abbreviated(FileManager.default.currentDirectoryPath)
        let failed = !shell.lastStatus.succeeded
        let status = failed ? "[\(shell.lastStatus.number)]".styled(DisplayStyle.red) + " " : ""
        return directory.styled(DisplayStyle.cyan) + " " + status
            + "❯".styled(failed ? DisplayStyle.red : DisplayStyle.green) + " "
    }

    /// A directory with the home directory written `~`, as the prompt shows it.
    static func abbreviated(_ directory: String) -> String {
        guard let home = ProcessInfo.processInfo.environment["HOME"],
            directory == home || directory.hasPrefix(home + "/")
        else { return directory }
        return "~" + directory.dropFirst(home.count)
    }
}

/// Why a `prompt` function can't be used.
struct PromptError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
