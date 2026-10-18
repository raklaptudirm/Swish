import Swiit

/// What you've entered at the prompt, oldest first.
public func history(in shell: HostContext) -> [String] {
    shell.history
}
