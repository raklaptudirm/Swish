import Foundation

// The environment other shells set up: a login's, from the system's profile, and a tool's that
// sets itself up for sh (`eval "$(brew shellenv)"`, a project's `env.sh`).

extension Shell {
    /// Runs `script` with `/bin/sh` and takes the environment it ends with: what it sets or changes
    /// is set here, and what it removes is removed. A `login` sh reads the system's profile first
    /// (`/etc/profile`, then `~/.profile`), which is what a login shell's environment is on Unix:
    /// on macOS, `path_helper`'s `PATH` and what nix-darwin or Homebrew add to it.
    ///
    /// What the script prints goes where the shell's output and errors go now. The environment
    /// comes back on a descriptor of its own, so that output can't be mistaken for it. What sh sets
    /// for itself (its `$_`, `$SHLVL` and working directory) is not taken.
    public func loadEnvironment(fromShell script: String, login: Bool = false) throws {
        guard let pipe = makePipe() else { throw LibraryError("can't make a pipe for /bin/sh") }
        // The environment is written once the script is done; one that exits first gives none.
        let program = script + "\nexec /usr/bin/env -0 >&3\n"
        let argv = ["/bin/sh"] + (login ? ["-l"] : []) + ["-c", program]
        // Ours that is also a target is copied out of the way first, as a pipeline's are, so the
        // order the child applies them in can't matter.
        let wanted = [STDOUT_FILENO: stdoutFD, STDERR_FILENO: stderrFD, 3: pipe.write]
            .filter { $0.key != $0.value }
        var descriptors: [(target: Int32, source: Int32)] = []
        var copies: [Int32] = []
        for (target, source) in wanted {
            var source = source
            if wanted.keys.contains(source) {
                source = fcntl(source, F_DUPFD_CLOEXEC, 10)
                copies.append(source)
            }
            descriptors.append((target, source))
        }
        defer { copies.forEach { close($0) } }
        let spawned = spawnProcess(
            "/bin/sh",
            argv,
            pgid: -1,
            descriptors: descriptors,
            terminal: nil
        )
        close(pipe.write)
        defer { close(pipe.read) }
        guard case .success(let pid) = spawned else {
            throw LibraryError("can't run /bin/sh")
        }

        var bytes: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = read(pipe.read, &buffer, buffer.count)
            if count > 0 {
                bytes += buffer[..<count]
            } else if count < 0, errno == EINTR {
                continue
            } else {
                break
            }
        }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0, errno == EINTR {}
        // Nothing came back: the script left before the end (an `exit`), so nothing is changed.
        guard !bytes.isEmpty else {
            throw LibraryError("/bin/sh ended before it gave its environment; was there an exit?")
        }

        var after: [String: String] = [:]
        for entry in bytes.split(separator: 0) {
            let text = String(decoding: entry, as: UTF8.self)
            guard let equals = text.firstIndex(of: "=") else { continue }
            after[String(text[..<equals])] = String(text[text.index(after: equals)...])
        }
        let own: Set = ["_", "SHLVL", "PWD", "OLDPWD"]
        let before = Dictionary(
            environment.all().map { ($0.name, $0.value) },
            uniquingKeysWith: { $1 }
        )
        for (name, value) in after where !own.contains(name) && before[name] != value {
            environment.set(name, value)
        }
        for name in before.keys where !own.contains(name) && after[name] == nil {
            environment.set(name, nil)
        }
    }

    /// Sets the shell up as a login shell: the environment the system's login profile makes
    /// (`loadEnvironment(fromShell:login:)`). A terminal starts the login shell with little more
    /// than `HOME` and `USER` set, so without it the programs nix-darwin or Homebrew install are
    /// not on `PATH`. A profile that fails is reported, and the shell starts with what it has.
    public func setUpLogin() {
        do { try loadEnvironment(fromShell: ":", login: true) } catch {
            report("error: the login profile: \(error)")
        }
    }
}
