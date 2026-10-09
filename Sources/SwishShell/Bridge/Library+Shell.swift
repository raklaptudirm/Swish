import SwishCore

extension Library {
    /// The shell's own: `ls`, `ps`, `pwd`, `with(env:)`, `readLine`, `history`
    /// and the types they use (SwishShellLibrary).
    nonisolated(unsafe) static let shell = Library(
        types: Bridge.shellTypes, columns: Bridge.shellColumns,
        enumStyles: Bridge.shellEnumStyles, functions: Bridge.shellFunctions
    )
}
