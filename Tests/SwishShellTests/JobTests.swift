@testable import Swiit
@testable import SwishShell
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
    #expect(try output("let a = async sleep 0.1; let b = async sleep 0.2; jobs; jobs.count; await; jobs; await; jobs.count")
        == "id  state    command\n 1  running  sleep 0.1\n 2  running  sleep 0.2\n2\nid  state  command\n 1  done   sleep 0.1\n0\n")
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
    #expect(status("func f() {}; async f") == 1) // Swish functions can't run in the background yet
    #expect(status("async 1 + 2") == 2)
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
