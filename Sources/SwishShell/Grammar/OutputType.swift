@_spi(Layer) import SwishShellLibrary
@_spi(Layer) import Swiit

extension TypeAnnotation {
    /// What `$(…)` gives: a command's output, a Swift type of the shell's library like any other, held as it is.
    static let output = TypeAnnotation.named("Output")
}
