@_spi(Layer) import Swiit

/// What you've entered at the prompt, oldest first.
@_spi(Layer) public func history(in shell: HostContext) -> [String] {
    shell.history
}
