@_spi(Shell) import Swiit
@_spi(Shell) @testable import SwishShell
import Testing

private func output(_ source: String, in shell: Shell = Shell()) throws -> String {
    try onLargeStack { try shell.capturing { shell.enter(source) } }
}

private func status(_ source: String) -> Int32 {
    let shell = Shell()
    _ = try? onLargeStack { try shell.capturing { shell.execute(source) } }
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
    #expect(try output("struct P: Equatable { var x: Int; var y = 0 }; P(x: 1) == P(x: 1, y: 0); P(x: 1) != P(x: 2)") == "true\ntrue\n")
    #expect(try output(point + "Point(x: 1) == Point(x: 1, y: 0)") == "") // `==` needs Equatable
    #expect(try output(point + "var a = Point(x: 1); var b = a; b.x = 9; a.x") == "1\n")
}

@Test func mutatingMethodsChangeTheVariable() throws {
    #expect(try output(point + "var p = Point(x: 3, y: 4); p.move(by: 1); p; p.reset(); p") == "Point(x: 4, y: 5)\nPoint(x: 0, y: 0)\n")
    // Inside a struct held by another.
    let line = point + "struct Line { var start: Point; var end: Point }\n"
    #expect(try output(line + "var l = Line(start: Point(x: 0), end: Point(x: 5)); l.end.move(by: 2); l.end")
        == "Point(x: 7, y: 2)\n")
    #expect(try output(point + #"let q = Point(x: 1); q.move(by: 1)"#)
        == "")
    // A method that isn't mutating can't change self.
    #expect(status("struct C { var n: Int; func bump() { n += 1 } }; var c = C(n: 1); c.bump()") == 2)
}

@Test func assigningToPartsOfValues() throws {
    #expect(try output("var xs = [1, 2, 3]; xs[1] = 20; xs[0] += 5; xs") == "[6, 20, 3]\n")
    #expect(try output(#"var r = ["a": 1]; r["b"] = 2; r["a"] = 3; var t = (a: 1, b: 2); t.a *= 3; r; t"#) == #"["a": 3, "b": 2]"# + "\n" + "(a: 3, b: 2)\n")
    #expect(try output("var n = 10; n -= 3; n /= 7; n") == "1\n")
    #expect(try output(point + #"var p = Point(x: 1); p.x = "a""#)
        == "")
    #expect(try output(point + "var p = Point(x: 1); p.lengthSquared = 1")
        == "")
    #expect(status("let xs = [1]; xs[0] = 2") == 2)
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
    #expect(status(temp + "Temp(celsius: 1, extra: 2)") == 2)
    #expect(status("struct S { var a: Int; init() {} }; S()") == 1)
    // `let` properties are fixed once made.
    #expect(status(temp + "var t = Temp(celsius: 1); t.celsius = 2") == 2)
}

@Test func structsAsTypes() throws {
    #expect(try output(point + "func far(_ p: Point) -> Int { p.x }; far(Point(x: 7))") == "7\n")
    #expect(status(point + #"func far(_ p: Point) -> Int { p.x }; far(["x": 1])"#) == 2)
    #expect(try output(point + "func origin() -> Point { Point(x: 0) }; origin()") == "Point(x: 0, y: 0)\n")
    // Defaults for `let`s with a value aren't in the memberwise init.
    #expect(try output("struct V { let major = 1; var minor: Int }; V(minor: 2)") == "V(major: 1, minor: 2)\n")
    #expect(try output("struct S { var a: Int }; S") == "struct S\n")
}

private let counted = """
struct Counter: Equatable {
    var n: Int
    static let zero = Counter(n: 0)
    static let step = 2
    static var made = 0
    static var next: Int { step + made }
    static func make(_ n: Int) -> Counter { made += 1; return Counter(n: n * step) }
    func bumped() -> Counter { Counter(n: n + Counter.step) }
}

"""

@Test func staticMembersBelongToTheType() throws {
    // Values, computed values and methods are read and called on the type; a
    // static value may be made of the type itself, and the others by bare name.
    #expect(try output(counted + "Counter.zero; Counter.step; Counter.make(3); Counter.next") == "Counter(n: 0)\n2\nCounter(n: 6)\n3\n")
    #expect(try output(counted + "Counter.zero.bumped(); let f = Counter.make; f(1)") == "Counter(n: 2)\nCounter(n: 2)\n")
    // A static var is assigned through its type, a let isn't.
    #expect(try output(counted + "Counter.made += 5; Counter.made = Counter.made * 2; Counter.made") == "10\n")
    #expect(status(counted + "Counter.step = 3") != 0)
    #expect(status(counted + #"Counter.made = "x""#) != 0)
    #expect(status(counted + "Counter.nope") != 0)
    #expect(status(counted + "Counter.next = 1") != 0)
}

@Test func staticNamesAreNotInScopeInInstanceMethods() throws {
    // As in Swift, an instance method reaches a static member through the type.
    #expect(status("struct S { static let k = 1; func f() -> Int { k } }; S().f()") != 0)
    #expect(try output("struct S { static let k = 1; func f() -> Int { S.k } }; S().f()") == "1\n")
}

private let entry = """
struct Entry: Tabular {
    var name: String
    var size: Int
    var path: String
    static let columns: [DisplayColumn] = ["size", "name"]
}
let es = [Entry(name: "a", size: 1, path: "/x"), Entry(name: "b", size: 22, path: "/y")]

"""

@Test func aStructSaysWhichColumnsATableStartsWith() throws {
    // The columns it lists, in its order; `table` shows every field, and the rest are still there.
    #expect(try output(entry + "es") == "size  name\n   1  a\n  22  b\n")
    #expect(try output(entry + "es | table") == "name  size  path\na        1  /x\nb       22  /y\n")
    #expect(try output(entry + "es | filter { $0.size > 1 } | select name path") == "name  path\nb     /y\n")
    // Tabular is asked of a struct, and needs the static member that says it.
    #expect(status("struct P: Tabular { var x: Int }") != 0)
    #expect(status("struct P: Tabular { var x: Int; static let columns = 1 }") != 0)
    #expect(status("enum E: Tabular { case a }") != 0)
}
