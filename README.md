# Swish

**A shell that speaks Swift.** Commands work the way they do in any shell;
everything else is a small Swift-flavored language, with values instead of
text flowing through pipelines, and Swift packages you can `import` and use
right from the prompt.

```swift
let n = 3
if n > 2 { echo "big \(n)" }

ls | filter { $0.size > 1.kb } | sorted --by size -r | prefix 3
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
greet --help                  // or `help greet`; `help` lists every function
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
ps | filter { $0.name == "launchd" } | select pid user

func double(@input _ n: Int) -> Int { n * 2 }
seq 5 | double | tr 0-9 a-j

ls | grep Package          // records reach other programs as their table rows
ls | get name | wc -l      // or pick the field you want
```

### Enums and switch

Swift's enums, with raw and associated values, and `switch` with its
patterns. Builtins use them too: `ls` says what each entry is with a
`FileType`.

```swift
enum Result { case ok, failed(code: Int, String) }

func describe(_ r: Result) -> String {
    switch r {
    case .ok: return "fine"
    case .failed(let code, let why) where code > 1: return "\(code): \(why)"
    case .failed: return "failed"
    }
}
describe(.failed(code: 2, "no such file"))

ls | filter { $0.type == .directory }
```

### Structs

Structs are records with a type: computed properties, methods and
`mutating`, and they still work as rows in tables and pipelines.

```swift
struct Point {
    var x: Int
    var y: Int = 0
    var lengthSquared: Int { x * x + y * y }
    mutating func move(by d: Int) { x += d; y += d }
}

var p = Point(x: 3, y: 4)
p.move(by: 1)
[p, Point(x: 1)] | filter { $0.lengthSquared > 1 }   // a table: x, y
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

### Swift packages as commands

Mark functions in a Swift package with `@SwishExport` and `import` it: each
one becomes a command with flags, `--help` and piping, derived from its
signature and doc comment, just like a Swish `func`.

```swift
// In a package that depends on SwishKit:
/// Greets someone.
@SwishExport
public func greet(_ name: String, @Flag("n") times: Int = 1) -> [String] { … }

@SwishExport
public func longest(@Input _ lines: [String]) -> String? { … }
```

```swift
import Tools from "~/code/tools"   // builds it, and loads the library
greet Rak -n 2
ls | get name | longest
```

Enums that conform to `SwishEnum` work as arguments, `Encodable` results
become records, and `@SwishObject` classes are live objects with their
properties and methods. See [`Examples/Tools`](Examples/Tools).

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
Values print as Swift would show them, colored like the input and broken
over lines when they're wide.

## Getting started

Swish needs Swift 6 on macOS or Linux. It's all Swift: what differs between the two (starting
programs, `ps`, file details, plugin libraries) is in `Sources/SwishCore/Platform`.

```sh
swift build -c release
.build/release/swish                  # start the shell
.build/release/swish -c 'ls | count'  # run one line
.build/release/swish script.swish a b    # run a script, with arguments
```

<details>
<summary>Development builds and tests</summary>

```sh
swift build
.build/debug/swish
swift run swish -c 'run test'     # unit tests, plus pty-driven job-control, editor and background-job tests
swift run swish -c 'run bridge'   # regenerate the standard library bridge (after a toolchain update)
```

The tasks are functions in [`Tasks.swish`](Tasks.swish); inside Swish, `run` lists them and
`run test` runs one. `run test` works with just the Command Line Tools installed, where
`swift test` alone can't find the Testing framework. The terminal tests need
`expect`, which macOS ships (on Linux, install it from your package manager).

| Path | What |
|---|---|
| `Packages/SwishKit` | `Value` and the plugin API, with the `@SwishExport` and `@SwishObject` macros. A separate package so it links as a **dynamic library** shared by the shell and every plugin. |
| `Sources/SwishCore` | Parser, interpreter, pipelines, job control, builtins, line editor. |
| `Sources/SwishCore/Platform` | What differs between macOS and Linux: `posix_spawn` with process groups and terminal handoff, `ps`, file status, and reading a plugin library's exports. |
| `Sources/swish` | The executable. |
| `Tests/Interactive` | `expect` scripts that drive the shell through a real terminal. |
| `Examples/Tools` | An example plugin, which the tests import. |
| `Sources/swish-bridge` | Reads Swift's symbol graphs and generates the glue that bridges the standard library (`run bridge`). |

</details>

## Design

- [Structured pipelines](docs/design/pipeline.md): values instead of text,
  the boundaries with external programs, formatting at the end, failures
- [Functions and commands](docs/design/callables.md): one callable, with a
  Swift call syntax and a command-line syntax derived from its signature
- [Shell syntax](docs/design/syntax.md): where Swish departs from POSIX:
  comments, the environment, command output, scripts, redirects, background jobs
- [Plugins](docs/design/plugins.md): exporting from Swift, and how `import`
  builds, loads and registers a package

## Roadmap

- [x] **Shell basics**: REPL, `PATH` lookup, pipes, process groups, `^C`/`^Z`, `fg`/`jobs`,
  `cd`/`pwd`/`exit`
- [x] **Redirections and globbing**: `>`, `>>`, `<`, `e>`, `e>o`, `o>e`, `o+e>` applied in order
  (for Swish functions too); `*`, `[…]`, `**`; `;`, `&&`, `||`
- [x] **Background jobs**: `async`/`await` and `Job` values instead of `&`, `fg` and `bg`; `jobs`,
  `resume()`, `cancel()`, per-job terminal modes, notices before the prompt
- [x] **The language**: two-mode parsing, `let`/`var`, operators, lists, ranges, `if`/`if let`,
  `??`, loops, `func`, closures and trailing closures, `$(…)` as `Output`, `try`/`try?`/`try!`,
  `do`/`catch`, `env`, `//` comments, scripts with `args`, `main`, `defer` and `#filePath`
- [x] **Enums and switch**: cases, raw and associated values, `.case` resolved by context,
  `switch` with Swift's patterns, `if case`; `FileType` from `ls`, enum parameters on the command line
- [ ] **Static types** ([plan](docs/design/types.md)): checked before anything runs, as in Swift
  - [x] The checker's core: inference, functions and `Void`, structs, enums, optionals with `!`
    and `?.`, tuples, dictionaries, `let x: T`
  - [x] Function values, closures' results inferred, static overloads, Swift's rules for `throws`
  - [x] Protocols (`Equatable`, `Comparable`, …), key paths, generic builtins declared in a
    Swish prelude, typed pipelines with stages resolved from their input
  - [x] `Any` casts (`as?`, `as!`, `is`), the `JSON` type, optional subscripts
  - [ ] Swish types are Swift types: one type system read from Swift's symbol graphs, any package
    usable as it is, generated Swift twins for Swish types ([design](docs/design/swift-interop.md));
    so far the standard library's non-mutating members on `String`, `Int`, `Double`, `Bool`,
    `Array`, `Set`, `Dictionary`, `Optional` and ranges, with `1...5` a real `ClosedRange<Int>`,
    and swift-system's `FilePath`
- [x] **Methods as stages**: after a `|`, a name is a method of what's piped in: the sequence's
  (`sorted`, `filter`, `map`, `prefix`, `reversed`, `count`, `select`, `get`, as in Swift, also
  `xs.sorted(by: \.size)`), then each item's (`points | describe`, `jobs | cancel`); stages
  written as calls, `ls | sorted(by: \.size)`; trailing closures for labeled parameters
- [x] **Structs**: typed records with the memberwise init or custom `init`s, computed
  properties, methods and `mutating`; assignment into values (`p.x = 1`, `xs[0] += 5`)
- [x] **Callables**: command lines derived from signatures, `@input` streaming, `@flag`,
  `--help` from doc comments, overloads, `foreign` and `which`
- [x] **Structured data**: records, file sizes and dates, `Encodable` → `Value`, views and
  tables, per-item errors, `members`, and builtins (`ls`, `ps`, `from json`, `to json`/`to text`,
  `table`, `list`),
  objects shown through their fields
  - [x] Live objects for bridged Swift values
  - [ ] Errors as values you can inspect after the fact
  - [x] Paths: swift-system's `FilePath` (the standard library's once SE-0529 ships), from `pwd`
    and `ls`'s `path` and `target`
  - [ ] Durations
  - [ ] A lazy `ls`
- [x] **Line editor**: persistent history (`$SWISH_HISTORY`, default `$XDG_STATE_HOME/swish/history`) with
  prefix search and `^R`, completion from signatures, highlighting from the parser,
  multi-line editing and wrapping
- [x] **Display**: bare values shown with their `debugDescription`, pretty-printed to fit the
  terminal; color for what matters (errors, job states, directories) and for structure
- [x] **Plugin ABI**: `@SwishExport` functions with `@Flag`/`@Input`, `SwishEnum` enums,
  `@SwishObject` classes and `Encodable` results; exports found by symbol, no list to keep;
  `import Name from "path"` builds, loads and registers a local package
- [ ] **`import` from anywhere**: now part of static types' phase 5: any package or SDK module,
  from a URL or path, without annotations
