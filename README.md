# Swish

**A shell that speaks Swift.** Commands work the way they do in any shell;
everything else is a small Swift-flavored language, with values instead of
text flowing through pipelines. The goal is to `import` Swift packages and
use them right from the prompt.

```swift
let n = 3
if n > 2 { echo "big \(n)" }

ls | where { $0.size > 1.kb } | sort --by size -r | first 3
```

```
name       type    size  modified
README.md  file  3.1 KB  2026-09-27 19:47
```

## A tour

### Commands and Swift, side by side

A line that starts like a command runs as one; a line that starts like an
expression is Swift. Variables, functions, loops and closures are all there.

```swift
for i in 1...3 { echo "step \(i)" }

let files = $(git ls-files docs)
for file in files { echo "doc: \(file)" }   // command output iterates by line
echo "on \($(git branch --show-current))"
```

### Every function is also a command

A `func` gets a command-line interface derived from its signature: argument
labels become `--flags`, `Bool`s become switches, and `///` doc comments
become `--help`.

```swift
/// Greets someone.
/// - Parameter times: how many times to greet
func greet(_ name: String, @flag("n") times: Int = 1, loud: Bool = false) {
    for _ in 1...times {
        if loud { echo "HI \(name)" } else { echo "hi \(name)" }
    }
}

greet("Rak", times: 2)        // as Swift
greet Rak -n 2 --loud         // as a command
greet --help
```

```
Greets someone.

Usage:
  greet [--times <Int>] [--loud] <name>

Arguments:
  <name>             (String)

Options:
  -n, --times <Int>  how many times to greet (default: 1)
      --loud         (default: false)
  -h, --help         Show this help
```

### Structured pipelines

Builtins like `ls` and `ps` produce records, which you filter and reshape
with closures and fields; they're laid out as tables only at the end.
Functions stream values from one to the next, and text to and from other
programs.

```swift
ps | where { $0.name == "launchd" } | select pid user

func double(@input _ n: Int) -> Int { n * 2 }
seq 5 | double | tr 0-9 a-j

ls | grep Package          // records reach other programs as their table rows
ls | get name | wc -l      // or pick the field you want
```

### Failure is a value until you `try`

`$(…)` gives the command's output and how it exited. It only throws when
you say `try`, and Swift's `try?`, `try!` and `do`/`catch` mean what you'd
expect.

```swift
let head = $(git rev-parse HEAD)
if !head.status.succeeded { echo "not a repository" }

let editor = (try? $(git config core.editor)) ?? "vi"

do {
    let log = try $(make)
} catch {
    echo "make failed with \(error.status.code)"
}
```

### Background jobs are values

There's no `&`: `async` starts a job and hands it to you, and `await`
waits for it, bringing it to the foreground as `fg` would.

```swift
let build = async swift build
let page = async $(curl -s example.com)
echo "meanwhile…"
let html = await page             // its Output
try await build                   // throws if the build failed

jobs                              // background jobs, including ones you ^Z'd
await                             // bring back the most recent: the ^Z'd vim, say
```

### The rest of a shell, a little tidier

```swift
EDITOR=nano git commit            // environment for one command
env.PAGER = "less"                // or for the session
make e>o | tee build.log          // errors along with output
ls **/*.swift                     // globs, including **
foreign ls -la                    // the program, not the builtin `ls`
```

Interactively there's syntax highlighting, completion of commands, paths and
function flags, history with prefix and `^R` search, and multi-line editing.

## Getting started

Swish needs macOS and Swift 6.

```sh
swift build -c release
.build/release/swish                  # start the shell
.build/release/swish -c 'ls | count'  # run one line
.build/release/swish script.sw a b    # run a script, with arguments
```

<details>
<summary>Development builds and tests</summary>

```sh
swift build
.build/debug/swish
scripts/test.sh     # unit tests, plus pty-driven job-control, editor and background-job tests
```

`scripts/test.sh` works with just the Command Line Tools installed, where
`swift test` alone can't find the Testing framework. The terminal tests need
`expect`, which macOS ships.

| Path | What |
|---|---|
| `Packages/SwishKit` | `Value` and, later, the plugin API. A separate package so it links as a **dylib** shared by the shell and every compiled plugin. |
| `Sources/CShim` | `posix_spawn` with process groups and terminal handoff, plus the wait-status macros Swift can't import. |
| `Sources/SwishCore` | Parser, interpreter, pipelines, job control, builtins, line editor. |
| `Sources/swish` | The executable. |
| `Tests/Interactive` | `expect` scripts that drive the shell through a real terminal. |

</details>

## Design

- [Structured pipelines](docs/design/pipeline.md): values instead of text,
  the boundaries with external programs, formatting at the end, failures
- [Functions and commands](docs/design/callables.md): one callable, with a
  Swift call syntax and a command-line syntax derived from its signature
- [Shell syntax](docs/design/syntax.md): where Swish departs from POSIX:
  comments, the environment, command output, scripts, redirects, background jobs

## Roadmap

- [x] **Shell basics**: REPL, `PATH` lookup, pipes, process groups, `^C`/`^Z`, `fg`/`jobs`,
  `cd`/`pwd`/`exit`
- [x] **Redirections and globbing**: `>`, `>>`, `<`, `e>`, `e>o`, `o>e`, `o+e>` applied in order
  (for Swish functions too); `*`, `[…]`, `**`; `;`, `&&`, `||`
- [x] **Background jobs**: `async`/`await` and `Job` values instead of `&`, `fg` and `bg`; `jobs`,
  `resume()`, `cancel()`, per-job terminal modes, notices before the prompt
- [x] **The language**: two-mode parsing, `let`/`var`, operators, lists, ranges, `if`/`if let`,
  `??`, loops, `func`, closures and trailing closures, `$(…)` as `Output`, `try`/`try?`/`try!`,
  `do`/`catch`, `env`, `//` comments, scripts with `args` and `main`
- [x] **Callables**: command lines derived from signatures, `@input` streaming, `@flag`,
  `--help` from doc comments, overloads, `foreign` and `which`
- [x] **Structured data**: records, file sizes and dates, `Encodable` → `Value`, views and
  tables, per-item errors, `members`, and builtins (`ls`, `ps`, `where`, `select`, `get`,
  `sort`, `first`, `count`, `reverse`, `from json`, `to json`/`to text`, `table`, `list`)
  - [ ] Live objects for bridged Swift values (with the plugin ABI)
  - [ ] Errors as values you can inspect after the fact
  - [ ] Paths and durations
  - [ ] A lazy `ls`
- [x] **Line editor**: persistent history (`$SWISH_HISTORY`, default `~/.swish_history`) with
  prefix search and `^R`, completion from signatures, highlighting from the parser,
  multi-line editing and wrapping
- [ ] **Plugin ABI**: SwishKit's plugin API and an `@SwishExport` macro, reusing the
  callable metadata
- [ ] **`import`**: `import Package from "url"`, with SwiftPM resolution, generated bridges and
  cached dylibs
