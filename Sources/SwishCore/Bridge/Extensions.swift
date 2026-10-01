import Foundation
import SwishKit

/// Members Swish adds to Swift's types, as an `extension String` would:
/// merged into the bridged types, so they're checked and called like
/// Swift's own.
extension Bridge {
    nonisolated(unsafe) static let extensions: [String: [BridgedMember]] = [
        "String": [styled],
    ]

    /// `"~/src".styled(.cyan, .bold)`: the text in colors or emphasis, as a
    /// prompt wants; plain where color is off (NO_COLOR set, TERM=dumb, or
    /// not writing to a terminal).
    nonisolated(unsafe) private static let styled = BridgedMember(
        kind: .method, name: "styled", isStatic: false,
        parameters: [Parameter(label: nil, name: "styles", type: .named("TextStyle"), variadic: true)],
        returns: .string, generics: [:], isThrowing: false, isRethrowing: false, isMutating: false, discardableResult: false,
        summary: "The text in colors or emphasis, plain where color is off.",
        body: .native { shell, args in
            guard case .string(let text)? = args["self"] else { return .nothing }
            guard case .list(let styles)? = args["styles"], !styles.isEmpty, !text.isEmpty,
                  Style.enabled(for: shell.stdoutFD) else {
                return .string(text)
            }
            // Each style's raw value is its terminal code.
            let codes = styles.compactMap { style -> String? in
                guard case .enumValue(let value) = style, case .string(let code)? = value.definition?.rawValue else { return nil }
                return code
            }
            return .string("\u{1B}[\(codes.joined(separator: ";"))m" + text + Style.reset)
        }
    )
}
