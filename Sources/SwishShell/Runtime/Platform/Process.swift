@_spi(Shell) import Swiit
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation

// MARK: Resource limits

/// A limit `ulimit` shows and sets: its flag, what it limits, the resource,
/// and how many bytes one unit is (1024 for sizes, as other shells count
/// them; 1 for counts and seconds).
struct ResourceLimit {
    let flag: Character
    let name: String
    let resource: Int32
    let unit: UInt64

    static let all: [ResourceLimit] = [
        ResourceLimit(flag: "c", name: "core file size (KiB)", resource: resource(RLIMIT_CORE), unit: 1024),
        ResourceLimit(flag: "d", name: "data segment size (KiB)", resource: resource(RLIMIT_DATA), unit: 1024),
        ResourceLimit(flag: "f", name: "file size (KiB)", resource: resource(RLIMIT_FSIZE), unit: 1024),
        ResourceLimit(flag: "n", name: "open files", resource: resource(RLIMIT_NOFILE), unit: 1),
        ResourceLimit(flag: "s", name: "stack size (KiB)", resource: resource(RLIMIT_STACK), unit: 1024),
        ResourceLimit(flag: "t", name: "cpu time (seconds)", resource: resource(RLIMIT_CPU), unit: 1),
        ResourceLimit(flag: "u", name: "processes", resource: resource(processLimit), unit: 1),
        ResourceLimit(flag: "v", name: "virtual memory (KiB)", resource: resource(RLIMIT_AS), unit: 1024),
    ]

    /// The soft (or hard) limit, in units; nil for unlimited.
    func current(hard: Bool) throws(Errno) -> UInt64? {
        var limits = rlimit()
        guard getrlimit(Self.id(resource), &limits) == 0 else { throw Errno(errno) }
        let value = UInt64(hard ? limits.rlim_max : limits.rlim_cur)
        return value == UInt64(unlimited) ? nil : value / unit
    }

    /// Sets the soft limit, the hard one, or both (as other shells do when
    /// neither is asked for); nil for unlimited.
    func set(_ units: UInt64?, soft: Bool, hard: Bool) throws(Errno) {
        var limits = rlimit()
        guard getrlimit(Self.id(resource), &limits) == 0 else { throw Errno(errno) }
        let value = units.map { rlim_t($0 * unit) } ?? unlimited
        if soft { limits.rlim_cur = value }
        if hard { limits.rlim_max = value }
        guard setrlimit(Self.id(resource), &limits) == 0 else { throw Errno(errno) }
    }

    /// RLIM_INFINITY, a macro Swift doesn't import on macOS.
    #if canImport(Darwin)
    private let unlimited = rlim_t(Int64.max)
    #else
    private let unlimited = rlim_t.max
    #endif

    // Linux's resources are an enum, and its functions take its raw value.
    // glibc names the processes limit with underscores and aliases it with a
    // macro, which Swift can't import for an enumerator.
    #if canImport(Glibc)
    private static let processLimit = __RLIMIT_NPROC
    private static func resource(_ value: __rlimit_resource) -> Int32 { Int32(value.rawValue) }
    private static func id(_ value: Int32) -> __rlimit_resource_t { __rlimit_resource_t(value) }
    #else
    private static let processLimit = RLIMIT_NPROC
    private static func resource(_ value: Int32) -> Int32 { value }
    private static func id(_ value: Int32) -> Int32 { value }
    #endif
}

// MARK: Input

/// The next byte of `fd`, or nil at its end.
func readByte(_ fd: Int32) -> UInt8? {
    var byte: UInt8 = 0
    return read(fd, &byte, 1) == 1 ? byte : nil
}

// MARK: umask

/// The mask new files are made without.
var fileCreationMask: mode_t {
    get {
        let current = umask(0)
        umask(current)
        return current
    }
    set { umask(newValue) }
}

// MARK: exec

/// Replaces the shell with the program at `path`: only returns, with the
/// error, if it can't. Signals the shell ignores or catches go back to
/// their defaults first, as the program expects them.
func replaceProcess(with path: String, _ argv: [String]) -> Errno {
    for caught in [SIGINT, SIGQUIT, SIGTSTP, SIGTTIN, SIGTTOU, SIGPIPE, SIGTERM, SIGHUP] {
        _ = signal(caught, SIG_DFL)
    }
    let arguments = argv.map { strdup($0) } + [nil]
    let environment = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
    execve(path, arguments, environment)
    return Errno(errno)
}
