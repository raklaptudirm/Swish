@testable @_spi(Layer) import Swiit
@_spi(Shell) @_spi(Layer) @testable import SwishShell
import Foundation
import Testing

@Test func whatTheShellsOwnFrontEndGivesRunsAsTheOldOneDid() throws {
    let count = ProcessInfo.processInfo.environment["SWISH_FUZZ"].flatMap(Int.init) ?? 300
    var generator = Generator(state: 20_261_016)
    let probe = Shell()
    var ran = 0, matched = 0
    var failures: [String: [String]] = [:]
    for _ in 0..<count {
        let pieces = 2 + generator.next(3)
        let choices = (0..<pieces).map { _ in generator.next(pieceCount) }
        let separator = separators[generator.next(separators.count)]
        let context = generator.next(8)
        let body = choices.enumerated().map { piece($0.offset, $0.element) }.joined(separator: separator)
        let outer = generator.next(8)
        let source = generator.next(3) == 0 ? wrap(wrap(body, in: context), in: outer) : wrap(body, in: context)
        let expected = (0..<pieces).map { "m\($0)\n" }.joined()
        let front = probe.makeFront()
        guard let cured = try? front.cure(source) else { continue }
        ran += 1
        let shell = Shell()
        let actual = (try? onLargeStack { try shell.capturing { shell.execute(cured) } }) ?? "<threw>"
        if actual == expected { matched += 1 } else {
            let why = actual.prefix(100).replacingOccurrences(of: "\n", with: "⏎")
            failures[String(why), default: []].append("\(source)\n   => \(cured)")
        }
    }
    print("RUN programs \(ran), ran as expected \(matched)")
    for (why, cases) in failures.sorted(by: { $0.value.count > $1.value.count }).prefix(10) {
        print("RUN FAILED x\(cases.count): \(why)\n   e.g. \(cases.min(by: { $0.count < $1.count })!.replacingOccurrences(of: "\n", with: "⏎"))")
    }
}
