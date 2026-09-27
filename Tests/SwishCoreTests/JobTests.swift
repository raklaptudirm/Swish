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

@Test func asyncStartsAJobAndAwaitWaitsForIt() throws {
    #expect(try output("let j = async sleep 0.2; j.state; j.id; let r = await j; j.state; r.status.code") == "running\n1\ndone\n0\n")
    #expect(try output("async sleep 0.1") == "[1] running  sleep 0.1\n")
}

@Test func asyncCapturesOutput() throws {
    #expect(try output(#"let p = async $(sh -c 'sleep 0.1; echo fetched'); echo meanwhile; (await p).text"#) == "meanwhile\nfetched\n")
}

@Test func awaitGivesTheOutputAndTryThrows() throws {
    #expect(try output(#"let f = async sh -c 'exit 3'; let r = await f; r.status.code"#) == "3\n")
    #expect(try output(#"let f = async sh -c 'exit 3'; do { try await f } catch { echo "caught \(error.status.code)" }"#) == "caught 3\n")
    #expect(status(#"let f = async sh -c 'exit 3'; try await f"#) == 3)
    // An awaited Output's status is the statement's.
    #expect(try output("let j = async true; await j && echo ok; let k = async false; await k || echo failed") == "ok\nfailed\n")
}

@Test func jobsAndBareAwait() throws {
    #expect(try output("let a = async sleep 0.1; let b = async sleep 0.2; jobs; jobs.count; await; jobs; await; jobs.count")
        == "[1] running  sleep 0.1\n[2] running  sleep 0.2\n2\n[1] done  sleep 0.1\n0\n")
    #expect(status("await") == 1) // nothing to await
}

@Test func cancellingAJob() throws {
    #expect(try output("let j = async sleep 5; j.cancel(); let r = await j; r.status.signal; j.state") == "15\ncancelled\n")
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
    #expect(try output("let j = async sleep 0.1; j.command; j.pids.count; j.output == nil; await j; j.output.status.code") == "sleep 0.1\n1\ntrue\n0\n")
    let names = try output("let j = async sleep 0.1; j | members | get name; await j")
    #expect(names == "id\ncommand\nstate\npids\noutput\nresume\ncancel\n")
}

@Test func whatAsyncAndAwaitRefuse() {
    #expect(status("await 5") == 1)
    #expect(status("func f() {}; async f") == 1) // Swish functions can't run in the background yet
    #expect(status("async 1 + 2") == 2)
}

@Test func fgAndBgNameTheirReplacements() {
    #expect(status("fg") == 2)
    #expect(status("bg") == 2)
}
