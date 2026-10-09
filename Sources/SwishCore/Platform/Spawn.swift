#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation

/// How a child ended or stopped, from `waitpid`'s status. The W… macros
/// don't import into Swift; the encoding is the same on macOS and Linux.
struct WaitStatus {
    let raw: Int32

    init(_ raw: Int32) { self.raw = raw }

    var exited: Bool { raw & 0x7f == 0 }
    var exitCode: Int32 { (raw >> 8) & 0xff }
    var signaled: Bool { raw & 0x7f != 0 && raw & 0x7f != 0x7f }
    var signal: Int32 { raw & 0x7f }
    var stopped: Bool { raw & 0xff == 0x7f }
}

// MARK: ^C

/// Set by the SIGINT handler, taken by `takeInterrupt()`. What a signal
/// handler may touch is a word it stores to, as C's `volatile sig_atomic_t`
/// is; the readers call through a function, so the load isn't hoisted.
nonisolated(unsafe) private var interrupted: sig_atomic_t = 0

/// Makes SIGINT (or the signals given) set a flag instead of ending the
/// shell, so ^C can stop code running in the shell itself, like a
/// `while true {}` loop, and a script can run its `defer`s first.
func catchInterrupts(_ signals: [Int32] = [SIGINT]) {
    var action = sigaction()
    let handler: @convention(c) (Int32) -> Void = { signal in interrupted = signal }
    #if canImport(Darwin)
    action.__sigaction_u.__sa_handler = handler
    #elseif canImport(Glibc)
    action.__sigaction_handler.sa_handler = handler
    #else
    action.__sa_handler.sa_handler = handler
    #endif
    action.sa_flags = SA_RESTART
    sigemptyset(&action.sa_mask)
    for signal in signals { sigaction(signal, &action, nil) }
}

/// Whether a caught signal arrived since the last call, clearing the flag.
@inline(never)
func takeInterrupt() -> Bool {
    takeInterruptSignal() != nil
}

/// The caught signal that arrived since the last call, if any, clearing it.
/// It clears only a signal it saw: clearing after reading nothing would wipe
/// one that arrived in between, and a script spinning in a loop (which asks
/// constantly) would sometimes survive its SIGTERM.
@inline(never)
func takeInterruptSignal() -> Int32? {
    let signal = interrupted
    guard signal != 0 else { return nil }
    interrupted = 0
    return Int32(signal)
}

// MARK: Spawning

/// Starts `path` with `argv` and the current environment.
///
/// `pgid` < 0 keeps the shell's process group, 0 starts a new group led by
/// the child, and > 0 joins that group. The child gets each of `descriptors`
/// (target: one of ours); ours mustn't be among the targets, so the order
/// doesn't matter, and other descriptors should be close-on-exec. With a
/// `terminal`, a child leading a new group owns it before it runs any code,
/// so it can read it without SIGTTIN.
///
/// Returns the child's pid, or the error number.
func spawnProcess(
    _ path: String, _ argv: [String], pgid: pid_t, descriptors: [(target: Int32, source: Int32)], terminal: Int32?
) -> Result<pid_t, Errno> {
    #if canImport(Darwin)
    var attributes: posix_spawnattr_t?
    var actions: posix_spawn_file_actions_t?
    #else
    var attributes = posix_spawnattr_t()
    var actions = posix_spawn_file_actions_t()
    #endif
    var error = posix_spawnattr_init(&attributes)
    guard error == 0 else { return .failure(Errno(error)) }
    defer { posix_spawnattr_destroy(&attributes) }
    error = posix_spawn_file_actions_init(&actions)
    guard error == 0 else { return .failure(Errno(error)) }
    defer { posix_spawn_file_actions_destroy(&actions) }

    // The interactive shell ignores job-control signals; children get the
    // defaults back and start with nothing blocked.
    var defaults = sigset_t()
    var empty = sigset_t()
    sigemptyset(&defaults)
    for signal in [SIGINT, SIGQUIT, SIGTSTP, SIGTTIN, SIGTTOU, SIGCHLD, SIGPIPE] { sigaddset(&defaults, signal) }
    sigemptyset(&empty)
    posix_spawnattr_setsigdefault(&attributes, &defaults)
    posix_spawnattr_setsigmask(&attributes, &empty)

    var flags = Int32(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)
    if pgid >= 0 {
        flags |= Int32(POSIX_SPAWN_SETPGROUP)
        posix_spawnattr_setpgroup(&attributes, pgid)
    }

    // The child must own the terminal before it can read from it, or it gets
    // SIGTTIN. Traditional shells call tcsetpgrp in the child between fork
    // and exec. On macOS the child starts suspended while we hand the
    // terminal over; glibc can have the child do it itself.
    let handoff = pgid == 0 ? terminal : nil
    #if canImport(Darwin)
    if handoff != nil { flags |= Int32(POSIX_SPAWN_START_SUSPENDED) }
    #elseif canImport(Glibc)
    if let handoff, let addTerminal = addTerminalAction { _ = addTerminal(&actions, handoff) }
    #endif
    posix_spawnattr_setflags(&attributes, Int16(flags))

    for (target, source) in descriptors { posix_spawn_file_actions_adddup2(&actions, source, target) }

    let arguments = argv.map { strdup($0) } + [nil]
    defer { arguments.forEach { free($0) } }
    // The environment as it is now (`withEnvironment` may have just set
    // some); Glibc only declares `environ` for _GNU_SOURCE.
    let environment = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
    defer { environment.forEach { free($0) } }
    var pid: pid_t = 0
    error = posix_spawn(&pid, path, &actions, &attributes, arguments, environment)
    guard error == 0 else { return .failure(Errno(error)) }

    if let handoff {
        #if canImport(Darwin)
        tcsetpgrp(handoff, pid)
        kill(pid, SIGCONT)
        #else
        // Without glibc's action (older glibc, or musl) the child may touch
        // the terminal before it's handed over; it's done as soon as we can.
        if addTerminalAction == nil { tcsetpgrp(handoff, pid) }
        #endif
    }
    return .success(pid)
}

#if canImport(Glibc)
/// glibc 2.35's `posix_spawn_file_actions_addtcsetpgrp_np`, which has the
/// child take the terminal for its new group before it execs. Looked up
/// when it runs, since Swift's Glibc module doesn't declare it and older
/// glibcs don't have it.
nonisolated(unsafe) private let addTerminalAction: (@convention(c) (UnsafeMutablePointer<posix_spawn_file_actions_t>, Int32) -> Int32)? = {
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: 0), "posix_spawn_file_actions_addtcsetpgrp_np") else { return nil }
    return unsafeBitCast(symbol, to: (@convention(c) (UnsafeMutablePointer<posix_spawn_file_actions_t>, Int32) -> Int32).self)
}()
#endif

/// An error number from the system, as `errno` has it.
struct Errno: Error {
    let code: Int32
    init(_ code: Int32) { self.code = code }
}
