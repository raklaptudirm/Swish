import Testing

@Test func executionNamesNothingOfShell() throws {
    let found: Set<String>
    do { found = try Layering.breaches() } catch {
        Issue.record("\(error)")
        return
    }

    // A new breach fails, and so does a known one that is gone: the list only shrinks.
    #expect(found.subtracting(Layering.known).sorted() == [])
    #expect(Layering.known.subtracting(found).sorted() == [])
}
