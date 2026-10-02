import SwishKit

/// What you've entered at the prompt, oldest first.
public func history(in shell: ShellContext) -> [String] {
    shell.history
}
