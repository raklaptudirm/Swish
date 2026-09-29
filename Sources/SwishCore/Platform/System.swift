#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation
import SwishKit

// What the shell asks of the system that isn't the same everywhere: a
// file's status, the processes running, a user's name. Everything else
// goes through Foundation or POSIX calls every platform has.

/// What `lstat` says about a path, named the same on every platform.
struct FileStatus {
    let mode: mode_t
    let size: Int64
    let owner: uid_t
    let modified: Date
    let accessed: Date
    /// When it was made, if the system keeps that.
    let created: Date?

    /// The path's status, not following a symlink; the error number if
    /// there's none.
    init(_ path: String) throws(Errno) {
        var info = stat()
        guard lstat(path, &info) == 0 else { throw Errno(errno) }
        mode = info.st_mode
        size = Int64(info.st_size)
        owner = info.st_uid
        #if canImport(Darwin)
        modified = Self.date(info.st_mtimespec)
        accessed = Self.date(info.st_atimespec)
        created = Self.date(info.st_birthtimespec)
        #else
        modified = Self.date(info.st_mtim)
        accessed = Self.date(info.st_atim)
        // stat has no birth time here; Foundation asks statx for it.
        created = (try? FileManager.default.attributesOfItem(atPath: path))?[.creationDate] as? Date
        #endif
    }

    var isDirectory: Bool { mode & mode_t(S_IFMT) == mode_t(S_IFDIR) }
    var isSymlink: Bool { mode & mode_t(S_IFMT) == mode_t(S_IFLNK) }
    var isFile: Bool { mode & mode_t(S_IFMT) == mode_t(S_IFREG) }

    /// `rwxr-xr-x`.
    var permissions: String {
        let bits = [S_IRUSR, S_IWUSR, S_IXUSR, S_IRGRP, S_IWGRP, S_IXGRP, S_IROTH, S_IWOTH, S_IXOTH]
        return bits.enumerated().map { index, bit in mode & mode_t(bit) != 0 ? ["r", "w", "x"][index % 3] : "-" }.joined()
    }

    private static func date(_ time: timespec) -> Date {
        Date(timeIntervalSince1970: TimeInterval(time.tv_sec) + TimeInterval(time.tv_nsec) / 1e9)
    }
}

/// A user's name, or their number if they have none.
func userName(_ uid: uid_t) -> String {
    getpwuid(uid).map { String(cString: $0.pointee.pw_name) } ?? String(uid)
}

/// A process `ps` lists.
struct ProcessEntry: Encodable {
    var pid: Int
    var ppid: Int
    var name: String
    var user: String
    var memory: FileSize?
    /// Seconds.
    var cpuTime: Double?
    var threads: Int?
}

#if canImport(Darwin)
/// Every process, by pid. sysctl lists every process without privileges;
/// proc_pidinfo adds detail, but only for processes we're allowed to
/// inspect.
func runningProcesses() throws(Errno) -> [ProcessEntry] {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
    var size = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0 else { throw Errno(errno) }
    let stride = MemoryLayout<kinfo_proc>.stride
    var processes = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 64)
    size = processes.count * stride
    guard sysctl(&mib, 3, &processes, &size, nil, 0) == 0 else { throw Errno(errno) }
    var timebase = mach_timebase_info()
    mach_timebase_info(&timebase)
    let secondsPerTick = Double(timebase.numer) / Double(timebase.denom) / 1e9

    return processes.prefix(size / stride).sorted { $0.kp_proc.p_pid < $1.kp_proc.p_pid }.map { process in
        let pid = process.kp_proc.p_pid
        // p_comm is cut to 16 bytes; pbi_name, when we can read it, isn't.
        var name = withUnsafeBytes(of: process.kp_proc.p_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        var bsd = proc_bsdinfo()
        if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 {
            let full = withUnsafeBytes(of: bsd.pbi_name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            if !full.isEmpty { name = full }
        }
        var task = proc_taskinfo()
        let hasTask = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, Int32(MemoryLayout<proc_taskinfo>.size)) > 0
        return ProcessEntry(
            pid: Int(pid), ppid: Int(process.kp_eproc.e_ppid), name: name, user: userName(process.kp_eproc.e_ucred.cr_uid),
            memory: hasTask ? FileSize(bytes: Int64(task.pti_resident_size)) : nil,
            cpuTime: hasTask ? (Double(task.pti_total_user + task.pti_total_system) * secondsPerTick * 100).rounded() / 100 : nil,
            threads: hasTask ? Int(task.pti_threadnum) : nil
        )
    }
}
#else
/// Every process, by pid, from /proc.
func runningProcesses() throws(Errno) -> [ProcessEntry] {
    let names: [String]
    do {
        names = try FileManager.default.contentsOfDirectory(atPath: "/proc")
    } catch {
        throw Errno(ENOENT)
    }
    let pageSize = Int64(sysconf(Int32(_SC_PAGESIZE)))
    let ticksPerSecond = Double(sysconf(Int32(_SC_CLK_TCK)))
    return names.compactMap(Int32.init).sorted().compactMap { pid in
        // `pid (name) state ppid …`; the name can hold spaces and parentheses,
        // so the fields are counted from the last `)`.
        guard let stat = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8),
              let open = stat.firstIndex(of: "("), let close = stat.lastIndex(of: ")") else { return nil }
        let fields = stat[stat.index(after: close)...].split(separator: " ")
        func field(_ number: Int) -> Int64? { fields.count > number - 3 ? Int64(fields[number - 3]) : nil }
        var name = String(stat[stat.index(after: open)..<close])
        // The name is cut to 15 characters; the program's is whole.
        if let command = try? Data(contentsOf: URL(fileURLWithPath: "/proc/\(pid)/cmdline")),
           let program = command.split(separator: 0).first, let path = String(bytes: program, encoding: .utf8),
           let last = path.split(separator: "/").last, last.hasPrefix(name) {
            name = String(last)
        }
        let status = (try? String(contentsOfFile: "/proc/\(pid)/status", encoding: .utf8)) ?? ""
        let uid = status.split(separator: "\n").first { $0.hasPrefix("Uid:") }?
            .split(whereSeparator: \.isWhitespace).dropFirst().first.flatMap { uid_t($0) }
        let ticks = (field(14) ?? 0) + (field(15) ?? 0)
        return ProcessEntry(
            pid: Int(pid), ppid: Int(field(4) ?? 0), name: name, user: uid.map(userName) ?? "?",
            memory: field(24).map { FileSize(bytes: $0 * pageSize) },
            cpuTime: (Double(ticks) / ticksPerSecond * 100).rounded() / 100,
            threads: field(20).map(Int.init)
        )
    }
}
#endif
