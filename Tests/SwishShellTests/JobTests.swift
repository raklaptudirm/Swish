import Swiit
@_spi(Shell) @_spi(Layer) @testable import SwishShell
import Foundation
import Testing

private func output(_ source: String, in shell: Shell = Shell()) throws -> String {
    try onLargeStack { try shell.capturing { shell.enter(source) } }
}

private func status(_ source: String) -> Int32 {
    let shell = Shell()
    _ = try? onLargeStack { try shell.capturing { shell.execute(source) } }
    return shell.lastStatus
}

@Test func asyncStartsAJobAndAwaitWaitsForIt() throws {
    #expect(try output("let j = async sleep 0.2; j.state; j.id; let r = await j; j.state; r.status.code") == "JobState.running\n1\nJobState.done\n0\n")
    #expect(try output("async sleep 0.1") == "[1] running  sleep 0.1\n")
}

@Test func asyncCapturesOutput() throws {
    #expect(try output(#"let p = async $(sh -c 'sleep 0.1; echo fetched'); echo meanwhile; (await p).text"#) == "meanwhile\n\"fetched\"\n")
}

@Test func awaitGivesTheOutputAndTryThrows() throws {
    #expect(try output(#"let f = async sh -c 'exit 3'; let r = await f; r.status.code"#) == "3\n")
    #expect(try output(#"let f = async sh -c 'exit 3'; do { try await f } catch { if let f = error as? CommandFailure { echo "caught \(f.status.code)" } }"#) == "caught 3\n")
    #expect(status(#"let f = async sh -c 'exit 3'; try await f"#) == 3)
    // An awaited Output's status is the statement's.
    #expect(try output("let j = async true; await j && echo ok; let k = async false; await k || echo failed") == "ok\nfailed\n")
}

@Test func jobsAndBareAwait() throws {
    // Which jobs there are, not how far along: a slow machine may finish one,
    // or both, already. A bare `await` waits for the latest; the other is
    // awaited by name, as a finished job may have been announced and gone.
    #expect(try output("let a = async sleep 0.1; let b = async sleep 0.2; jobs.map { $0.command }; jobs.count; await; await a; jobs.count")
        == "[\"sleep 0.1\", \"sleep 0.2\"]\n2\n0\n")
    #expect(status("await") == 1) // nothing to await
}

@Test func jobsAreDataForTablesAndPipelines() throws {
    let shell = Shell()
    shell.execute("let a = async sleep 0.2; let b = async sleep 0.2 | cat")
    // Fields like a record's: selected, filtered on, encoded.
    #expect(try output("jobs | select id command", in: shell) == "id  command\n 1  sleep 0.2\n 2  sleep 0.2 | cat\n")
    #expect(try output("jobs | filter { $0.pids.count == 2 } | get id", in: shell) == "2\n")
    #expect(try output("jobs | to json", in: shell).contains(#""state": "running""#))
    #expect(try output("jobs | table", in: shell).hasPrefix("id  command          state    pids       output\n"))
    // One job on its own is still a line.
    #expect(try output("a", in: shell) == "[1] running  sleep 0.2\n")
    // An enum type isn't data.
    #expect(try output("FileType", in: shell) == "enum FileType\n")
    shell.execute("await a; await b")
    #expect(status("FileType | select name") == 1)
}

@Test func cancellingAJob() throws {
    #expect(try output("let j = async sleep 5; j.cancel(); let r = await j; r.status.signal; j.state") == "15\nJobState.cancelled\n")
}

@Test func finishedJobsAreAnnouncedOnce() throws {
    let shell = Shell()
    shell.execute("async sleep 0.1; async sh -c 'exit 2'; sleep 0.4")
    // Listing jobs shows finished ones as done, without dropping them…
    #expect(try output("jobs.count", in: shell) == "2\n")
    // …and the prompt's announcement reports each once, then drops them.
    #expect(shell.announceJobs() == ["[1] done  sleep 0.1", "[2] failed (2)  sh -c 'exit 2'"])
    #expect(shell.announceJobs().isEmpty)
    #expect(shell.jobs.isEmpty)
}

@Test func jobMembers() throws {
    #expect(try output("let j = async sleep 0.1; j.command; j.pids.count; j.output == nil; await j; j.output!.status.code") == "\"sleep 0.1\"\n1\ntrue\n0\n")
    let names = try output("let j = async sleep 0.1; j | members | get name; await j")
    #expect(names == "id\ncommand\nstate\npids\noutput\nlines\nresume\ncancel\n")
}

@Test func whatAsyncAndAwaitRefuse() {
    #expect(status("await 5") == 2)
    #expect(status("await") == 1) // nothing to await
}

// Swish code as a task of its own, on a thread behind the interpreter's lock
// (https://github.com/raklaptudirm/Swiit/blob/main/Docs/async.md, step 4).

private func run(_ source: String) throws -> String {
    let shell = Shell()
    return try onLargeStack { try shell.capturing { shell.execute(source) } }
}

@Test func aTaskGivesItsValueToAwait() throws {
    #expect(try run("let t = async 1 + 2; print(await t)") == "3\n")
    #expect(try run("func twice(_ n: Int) -> Int { n * 2 }; let t = async twice(21); let n: Int = await t; print(n)") == "42\n")
    #expect(try run("let t = async { let a = 2; return a * 5 }; print(await t)") == "10\n")
    // A command with Swish in it runs as a task too, and gives its Output, as a command's job does.
    #expect(try run("func f() { echo hi }; let j = async f; print((await j).text)") == "hi\n")
}

@Test func tasksRunWhileOthersWait() throws {
    // Each waits half a second on a program; together they take about that long.
    let start = Date()
    #expect(try run("let a = async { $(sleep 0.5); return 1 }; let b = async { $(sleep 0.5); return 2 }; print((await a) + (await b))") == "3\n")
    #expect(Date().timeIntervalSince(start) < 0.9)
    // The task that started them carries on while they wait.
    #expect(try run("let t = async { $(sleep 0.3); print(\"later\") }; print(\"now\"); await t; print(t.output!.text)") == "now\nlater\n")
}

@Test func tasksShareTheGlobalsAndKeepTheirOutput() throws {
    #expect(try run("var n = 0; let t = async { for _ in 1...3 { n += 1; $(sleep 0.05) } }; await t; print(n)") == "3\n")
    // What a task prints is kept on its job, not written over the prompt.
    #expect(try run("let t = async { print(\"inside\") }; await t; print(\"[\" + t.output!.text + \"]\")") == "[inside]\n")
}

@Test func aTaskIsCancelledAndItsErrorsReachAwait() throws {
    // A task that never waits stops when it's cancelled, at its next step.
    #expect(try run("let t = async { var n = 0; while true { n += 1 } }; t.cancel(); let r = try? await t; print(t.state)") == "cancelled\n")
    // What it threw, `try await` throws.
    #expect(try run("let t = async { try $(sh -c 'exit 3') }; do { let r = try await t } catch { print(\"caught\") }") == "caught\n")
}

@Test func tasksAreJobs() throws {
    let output = try run("let t = async { $(sleep 0.2) }; print(jobs.map { $0.command }); await t; print(jobs.count)")
    #expect(output == "[\"{ $(sleep 0.2) }\"]\n0\n")
}

@Test func fgAndBgNameTheirReplacements() {
    #expect(status("fg") == 2)
    #expect(status("bg") == 2)
}

@Test func aJobsLinesComeAsTheyArrive() throws {
    // The job doesn't end for half a minute, so reading a line can't wait for that.
    let endless = #"let j = async $(sh -c 'echo first; echo second; exec sleep 30'); "#
    #expect(try output(endless + "j.lines() | prefix 1; j.cancel()") == "first\n")
    // Reading goes on from the last line read, in a loop as in a pipeline.
    #expect(try output(endless + #"j.lines() | prefix 1; for line in j.lines() { echo "got \(line)"; break }; j.cancel()"#) == "first\ngot second\n")
    #expect(try output(#"let k = async $(sh -c 'echo a; sleep 0.2; printf b'); for line in k.lines() { echo "line \(line)" }"#) == "line a\nline b\n")
    // Done, what it has left is its output's lines, and the Output is whole.
    #expect(try output(#"let k = async $(sh -c 'echo a; echo b'); await k; k.lines() | map { $0 + "!" }"#).hasSuffix("a!\nb!\n"))
}

// Cancellation wakes a wait, and a task ends with the scope that started it
// (https://github.com/raklaptudirm/Swiit/blob/main/Docs/async.md, step 5).

@Test func cancellingATaskEndsWhatItWaitsFor() throws {
    let start = Date()
    #expect(try run("let t = async { $(sleep 100) }; t.cancel(); let r = try? await t; print(t.state)") == "cancelled\n")
    // A task awaiting another is woken too, and the other carries on.
    #expect(try run("let a = async { $(sleep 0.3); return 1 }; let b = async { await a }; b.cancel(); let r = try? await b; print(b.state, await a)") == "cancelled 1\n")
    #expect(Date().timeIntervalSince(start) < 5)
}

@Test func aTaskEndsWithTheScopeThatStartedIt() throws {
    let start = Date()
    // A function returning cancels and waits for what it started.
    #expect(try run("var done = false; func g() { let t = async { $(sleep 100); done = true } }; g(); print(done)") == "false\n")
    // So does a task's body, for its own tasks.
    #expect(try run("let outer = async { let inner = async { $(sleep 100) }; return 1 }; print(await outer)") == "1\n")
    #expect(Date().timeIntervalSince(start) < 5)
    // The prompt is one scope: a task started there outlives the line.
    let shell = Shell()
    _ = try onLargeStack { try shell.capturing { shell.execute("let t = async { $(sleep 0.2); return 5 }") } }
    #expect(try onLargeStack { try shell.capturing { shell.execute("print(await t)") } } == "5\n")
}

// A task in the background reads the input only once it's awaited, and its
// reads let other tasks run (https://github.com/raklaptudirm/Swiit/blob/main/Docs/async.md, step 6).

@Test func aBackgroundTaskReadsTheInputWhenAwaited() throws {
    let saved = dup(STDIN_FILENO)
    let pipe = makePipe()!
    dup2(pipe.read, STDIN_FILENO)
    close(pipe.read)
    defer {
        dup2(saved, STDIN_FILENO)
        close(saved)
    }
    _ = "hello\n".withCString { write(pipe.write, $0, 6) }
    close(pipe.write)
    let source = "var read = false; let t = async { let line = readLine(); read = true; return line }; "
        + "$(sleep 0.2); print(read); print((await t) ?? \"none\"); print(read)"
    #expect(try run(source) == "false\nhello\ntrue\n")
}

// Swift's own concurrency in the shell (https://github.com/raklaptudirm/Swiit/blob/main/Docs/async.md, step 7).

@Test func swiftsTaskRunsInTheShell() throws {
    // Unlike `async { … }`, it isn't a job: it writes where its starter writes.
    #expect(try run("let t = Task { print(\"inside\"); return 2 }; let n = await t.value; print(n * 3, jobs.count)") == "inside\n6 0\n")
    #expect(try run("let t = Task { $(sh -c 'echo hi').text }; print(await t.value)") == "hi\n")
}

@Test func asyncLetAndForTryAwaitInTheShell() throws {
    let start = Date()
    let source = """
    func slow(_ n: Int) async -> Int { try? await Task.sleep(nanoseconds: 300_000_000); return n }
    async let a = slow(1)
    async let b = slow(2)
    print(await a + b)
    """
    #expect(try run(source) == "3\n")
    #expect(Date().timeIntervalSince(start) < 0.55)
    #expect(try run(#"let j = async $(sh -c 'echo a; echo b'); for try await line in j.lines() { print("got", line) }"#) == "got a\ngot b\n")
    #expect(try run("_ = 1 + 1; let _ = 2; print(\"ok\")") == "ok\n")
}

@Test func anAwaitedSwiftTaskReadsTheInput() throws {
    let saved = dup(STDIN_FILENO)
    let pipe = makePipe()!
    dup2(pipe.read, STDIN_FILENO)
    close(pipe.read)
    defer {
        dup2(saved, STDIN_FILENO)
        close(saved)
    }
    _ = "typed\n".withCString { write(pipe.write, $0, 6) }
    close(pipe.write)
    #expect(try run("let t = Task { readLine() ?? \"none\" }; print(await t.value)") == "typed\n")
}
