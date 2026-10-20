import Foundation
import Swiit

// The shell's own declarations are Resources/Prelude.swift, embedded in the target by Package.swift; the only part made at
// run time is the size units, from the table `FileSize` reads.

extension Shell {
    static var prelude: String {
        String(decoding: PackageResources.Prelude_swift, as: UTF8.self)
            .replacingOccurrences(of: "__JOB_MEMBERS__", with: Job.declaration) + fileSizeUnits
    }

    /// `2.mb` and `1.5.gib`: each unit a file size is written in is a property of `Int` and `Double`.
    private static var fileSizeUnits: String {
        let units = FileSize.units.sorted { ($0.value, $0.key) < ($1.value, $1.key) }
        func properties(of number: String, _ amount: String) -> String {
            units.map { "    var \($0.key): FileSize { FileSize(\(amount), multiplier: \($0.value)) }" }.joined(separator: "\n")
        }
        return "\nextension Int {\n\(properties(of: "Int", "Double(self)"))\n}\nextension Double {\n\(properties(of: "Double", "self"))\n}\n"
    }
}
