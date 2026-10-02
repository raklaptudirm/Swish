extension Sequence where Element: Hashable {
    /// The items without repeats, first ones kept.
    public func uniqued() -> [Element] {
        var seen: Set<Element> = []
        return filter { seen.insert($0).inserted }
    }
}
