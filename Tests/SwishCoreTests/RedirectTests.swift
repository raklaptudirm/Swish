@testable import SwishCore
import Testing

private func output(_ source: String, in shell: Shell = Shell()) throws -> String {
    try shell.capturing { shell.execute(source) }
}

/// A fresh directory with a few files, by absolute path, since tests run
/// in parallel and can't change the working directory.
private func scratch() throws -> String {
    let shell = Shell()
    let dir = try output("mktemp -d", in: shell).trimmingCharacters(in: .newlines)
    shell.execute("""
    mkdir -p \(dir)/src/deep '\(dir)/with space' \(dir)/.secret
    touch \(dir)/a.txt \(dir)/b.txt \(dir)/c.md \(dir)/.hidden \(dir)/src/x.swift \(dir)/src/deep/y.swift '\(dir)/with space/z.txt' \(dir)/.secret/s.swift
    """)
    return dir
}

// MARK: Globs

@Test func globPatterns() throws {
    let d = try scratch()
    #expect(Glob.expand("\(d)/*.txt") == ["\(d)/a.txt", "\(d)/b.txt"])
    #expect(Glob.expand("\(d)/[ac].*") == ["\(d)/a.txt", "\(d)/c.md"])
    #expect(Glob.expand("\(d)/[c].md") == ["\(d)/c.md"])
    #expect(Glob.expand("\(d)/?.md").isEmpty) // `?` is literal: no file is named "?.md"
    #expect(Glob.expand("\(d)/.*") == ["\(d)/.hidden", "\(d)/.secret"])
    #expect(Glob.expand("\(d)/*/") == ["\(d)/src/", "\(d)/with space/"])
    #expect(Glob.expand("\(d)/**/*.swift") == ["\(d)/src/deep/y.swift", "\(d)/src/x.swift"]) // not .secret
    #expect(Glob.expand("\(d)/nothing*").isEmpty)
    #expect(Glob.expand(Glob.escape("\(d)/with space") + "/*") == ["\(d)/with space/z.txt"])
}

@Test func wildcardDetection() {
    #expect(Glob.hasWildcards("*.txt"))
    #expect(Glob.hasWildcards("a[bc]"))
    #expect(!Glob.hasWildcards("["))
    #expect(!Glob.hasWildcards("[]"))
    #expect(!Glob.hasWildcards(#"\*.txt"#))
    #expect(!Glob.hasWildcards("what?"))
}

@Test func globsInCommands() throws {
    let d = try scratch()
    #expect(try output("echo \(d)/*.txt") == "\(d)/a.txt \(d)/b.txt\n")
    #expect(try output("let dir = \"\(d)/with space\"; echo \"$dir\"/*.txt") == "\(d)/with space/z.txt\n")
    #expect(try output("echo '\(d)/*.txt'") == "\(d)/*.txt\n")
    #expect(try output("ls \(d)/*.md | get name") == "\(d)/c.md\n") // builtins get the paths too
    #expect(try output("test [ = [ && echo ok") == "ok\n")
    let shell = Shell()
    #expect(try output("echo \(d)/*.nope", in: shell) == "")
    #expect(shell.lastStatus == 1)
}

// MARK: Redirects

@Test func writeAppendRead() throws {
    let d = try scratch()
    #expect(try output("echo one > \(d)/f; echo two >> \(d)/f; cat < \(d)/f") == "one\ntwo\n")
    #expect(try output("echo three > \(d)/f; cat \(d)/f") == "three\n")
}

@Test func redirectOrderMatters() throws {
    let d = try scratch()
    // Both into the file.
    #expect(try output("sh -c 'echo out; echo err >&2' > \(d)/both 2>&1; cat \(d)/both") == "out\nerr\n")
    // Only output into the file; errors go where output went before: the pipe.
    #expect(try output("sh -c 'echo out; echo err >&2' 2>&1 > \(d)/only | tr a-z A-Z; cat \(d)/only") == "ERR\nout\n")
    #expect(try output("sh -c 'echo out; echo err >&2' &> \(d)/amp; cat \(d)/amp") == "out\nerr\n")
    #expect(try output("sh -c 'echo err >&2' 2> \(d)/e; cat \(d)/e") == "err\n")
}

@Test func swapThroughDuplicates() throws {
    // `3>&1 1>&2 2>&3` swaps output and error: only the error is captured
    // (the output goes to the test's stderr).
    #expect(try output("sh -c 'echo out; echo err >&2' 3>&1 1>&2 2>&3") == "err\n")
    #expect(try output("sh -c 'echo out; echo err >&2' 2>&1 1>/dev/null") == "err\n")
}

@Test func redirectFailures() throws {
    let d = try scratch()
    let shell = Shell()
    #expect(try output("echo x > \(d)/no/such/file; echo after", in: shell) == "after\n")
    #expect(try output("echo x > \(d)/*.txt", in: shell) == "")
    #expect(shell.lastStatus == 1)
}

@Test func swishFunctionsAndBuiltinsRedirect() throws {
    let d = try scratch()
    let funcs = "func greet() { echo hi }; func double(@input _ n: Int) -> Int { n * 2 }; func boom() -> Int { 1 / 0 };"
    #expect(try output(funcs + "greet > \(d)/g; cat \(d)/g") == "hi\n")
    #expect(try output(funcs + "seq 3 > \(d)/n; double < \(d)/n") == "2\n4\n6\n")
    #expect(try output(funcs + "seq 2 | double > \(d)/d; cat \(d)/d") == "2\n4\n")
    #expect(try output("pwd > \(d)/p; cat \(d)/p").hasPrefix("/"))
    // A table written to a file looks as it would on screen, without color.
    let header = try output("ls \(d)/*.txt > \(d)/l; head -1 \(d)/l")
    #expect(header.hasPrefix("name ") && header.hasSuffix("type  size  modified\n") && !header.contains("\u{1B}"))
    // A function's errors follow its `2>`.
    let shell = Shell()
    #expect(try output(funcs + "boom 2> \(d)/err", in: shell) == "")
    #expect(shell.lastStatus == 1)
    #expect(try output("cat \(d)/err") == "swish: error: division by zero\n")
}

@Test func onlyTheEndsOfASwishRunRedirect() {
    let shell = Shell()
    _ = try? shell.capturing { shell.execute("func f(@input _ x: Int) -> Int { x }; seq 2 | f > /dev/null | f") }
    #expect(shell.lastStatus == 1)
}
