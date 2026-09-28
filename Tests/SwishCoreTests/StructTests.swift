@testable import SwishCore
import Testing

private func output(_ source: String, in shell: Shell = Shell()) throws -> String {
    try shell.capturing { shell.execute(source) }
}

private func status(_ source: String) -> Int32 {
    let shell = Shell()
    _ = try? shell.capturing { shell.execute(source) }
    return shell.lastStatus
}

private let point = """
struct Point {
    var x: Int
    var y: Int = 0
    var lengthSquared: Int { x * x + y * y }
    func describe() -> String { "(\\(x), \\(y))" }
    mutating func move(by d: Int) {
        x += d
        self.y += d
    }
    mutating func reset() { move(by: -x); y = 0 }
}

"""

@Test func structsAreTypedRecords() throws {
    #expect(try output(point + "Point(x: 3, y: 4); Point(x: 1)") == "Point(x: 3, y: 4)\nPoint(x: 1, y: 0)\n")
    // Fields, computed properties and methods, with members in scope.
    #expect(try output(point + "let p = Point(x: 3, y: 4); p.x; p.lengthSquared; p.describe()") == "3\n25\n\"(3, 4)\"\n")
    // Records underneath: tables, filters, JSON; and values like Swift's.
    #expect(try output(point + "[Point(x: 5), Point(x: 1)] | filter { $0.x > 1 }") == "x  y\n5  0\n")
    #expect(try output(point + "Point(x: 1) | to json | tr -d ' \\n'") == #"{"x":1,"y":0}"#)
    #expect(try output(point + "Point(x: 1) == Point(x: 1, y: 0)") == "true\n")
    #expect(try output(point + "var a = Point(x: 1); var b = a; b.x = 9; a.x") == "1\n")
}

@Test func mutatingMethodsChangeTheVariable() throws {
    #expect(try output(point + "var p = Point(x: 3, y: 4); p.move(by: 1); p; p.reset(); p") == "Point(x: 4, y: 5)\nPoint(x: 0, y: 0)\n")
    // Inside a struct held by another.
    let line = point + "struct Line { var start: Point; var end: Point }\n"
    #expect(try output(line + "var l = Line(start: Point(x: 0), end: Point(x: 5)); l.end.move(by: 2); l.end")
        == "Point(x: 7, y: 2)\n")
    #expect(try output(point + #"let q = Point(x: 1); do { q.move(by: 1) } catch { error.message }"#)
        == #""cannot use mutating method 'move' on 'q': it's a 'let' constant""# + "\n")
    // A method that isn't mutating can't change self.
    #expect(status("struct C { var n: Int; func bump() { n += 1 } }; var c = C(n: 1); c.bump()") == 1)
}

@Test func assigningToPartsOfValues() throws {
    #expect(try output("var xs = [1, 2, 3]; xs[1] = 20; xs[0] += 5; xs") == "[6, 20, 3]\n")
    #expect(try output(#"var r = ["a": 1]; r["b"] = 2; r.a *= 3; r"#) == #"["a": 3, "b": 2]"# + "\n")
    #expect(try output("var n = 10; n -= 3; n /= 7; n") == "1\n")
    #expect(try output(point + #"var p = Point(x: 1); do { p.x = "a" } catch { error.message }"#)
        == #""Point.x must be Int, not String""# + "\n")
    #expect(try output(point + "var p = Point(x: 1); do { p.lengthSquared = 1 } catch { error.message }")
        == #""cannot assign to 'lengthSquared': it's a computed property""# + "\n")
    #expect(status("let xs = [1]; xs[0] = 2") == 1)
    #expect(status("var xs = [1]; xs[5] = 2") == 1)
}

@Test func customInitializers() throws {
    let temp = """
    struct Temp {
        let celsius: Double
        var fahrenheit: Double { celsius * 9 / 5 + 32 }
        init(fahrenheit f: Double) { celsius = (f - 32) * 5 / 9 }
        init(celsius: Double) { self.celsius = celsius }
    }

    """
    #expect(try output(temp + "Temp(fahrenheit: 212); Temp(celsius: 20).fahrenheit") == "Temp(celsius: 100.0)\n68.0\n")
    // An init replaces the memberwise one, and must set everything.
    #expect(status(temp + "Temp(celsius: 1, extra: 2)") == 1)
    #expect(status("struct S { var a: Int; init() {} }; S()") == 1)
    // `let` properties are fixed once made.
    #expect(status(temp + "var t = Temp(celsius: 1); t.celsius = 2") == 1)
}

@Test func structsAsTypes() throws {
    #expect(try output(point + "func far(_ p: Point) -> Int { p.x }; far(Point(x: 7))") == "7\n")
    #expect(status(point + #"func far(_ p: Point) -> Int { p.x }; far(["x": 1])"#) == 1)
    #expect(try output(point + "func origin() -> Point { Point(x: 0) }; origin()") == "Point(x: 0, y: 0)\n")
    // Defaults for `let`s with a value aren't in the memberwise init.
    #expect(try output("struct V { let major = 1; var minor: Int }; V(minor: 2)") == "V(major: 1, minor: 2)\n")
    #expect(try output("struct S { var a: Int }; S") == "struct S\n")
}
