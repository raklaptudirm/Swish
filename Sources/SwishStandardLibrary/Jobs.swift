import SwishKit

/// How a job is going: its `state`.
public enum JobState: Comparable, CaseIterable, DisplayStyled {
    case running, stopped, done, cancelled

    public var displayStyle: DisplayStyle? {
        switch self {
        case .running: .green
        case .stopped: .yellow
        case .cancelled: .dim
        case .done: nil
        }
    }

    public static func < (lhs: JobState, rhs: JobState) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}
