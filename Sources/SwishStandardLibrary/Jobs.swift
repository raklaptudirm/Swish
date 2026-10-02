/// How a job is going: its `state`.
public enum JobState: Comparable, CaseIterable {
    case running, stopped, done, cancelled

    public static func < (lhs: JobState, rhs: JobState) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}
