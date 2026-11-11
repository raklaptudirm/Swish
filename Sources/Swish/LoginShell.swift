import SwishShell

/// Sets the shell up as a login shell: the environment the system's login profile makes. A
/// terminal starts the login shell with little more than `HOME` and `USER` set, so without it the
/// programs nix-darwin or Homebrew install are not on `PATH`. A profile that fails is reported,
/// and the shell starts with what it has.
func setUpLogin(_ shell: Shell) {
    do { try shell.loadEnvironment(fromShell: ":", login: true) } catch {
        shell.report("error: the login profile: \(error)")
    }
}
