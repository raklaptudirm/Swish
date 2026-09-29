# Shell syntax

Status: **implemented**.

Swish started from POSIX shell syntax where it had no reason to differ.
These are the places where Swift, or just clarity, won instead.

## Comments

`//` and `///`, as in Swift. `//` only starts a comment at the start of a
word, so `https://example.com` is untouched. `#` is ordinary text
(`echo #tag`), except `#!` on the first line of a script.

```swift
/// Repeats a greeting.          // documentation for the func below
/// - Parameter times: how many times
func greet(_ name: String, @flag("n") times: Int = 1) { … }
```

## Strings

In commands, double-quoted strings interpolate `$name`, `$(…)` and `\(…)`,
so `cat "$dir"/*.txt` works. In expressions they're pure Swift: only `\(…)`
interpolates, and `"costs $5"` or `"$HOME"` are literal.

## The environment

`env` is the environment as a value; `env.NAME` is nil when it's unset.

```swift
env.EDITOR = "vim"               // set, for this session and what it runs
env.EDITOR = nil                 // unset
let home = env.HOME ?? "/"
env["PATH"]

EDITOR=nano git commit           // for one command, as in POSIX shells
with(env: ["EDITOR": "nano"]) {  // for a block
    git commit
}
```

`env.NAME` always means the variable NAME, even one called `count`. The
program `/usr/bin/env` is `foreign env …`, though `NAME=value cmd` covers
what it's usually for.

`with(env:)` uses a trailing closure, which Swish supports as Swift does,
except where `{` starts a body: after `if`, `while` and `for … in`.

## Command output and failure

`$(…)` gives an `Output`: the command's text and how it exited. It's a
collection of lines, so iterating, counting and indexing go by line, as
in other shells; where a String is wanted (interpolation, `==` with a
String, a command argument, a `String` parameter) it's the whole text.
Other String operations go through `.text`.

Like every value, an Output also has a `description`, its textual form as
in Swift's `CustomStringConvertible`, which here is the same text. `.text`
is the one to use for the output itself: `description` is how a value
shows, and isn't promised to stay a plain copy of the data.

```swift
let r = $(git status --short)
for line in r { … }              // line by line
r.count; r[0]; r.first           // lines
r.text                           // the whole text
r.status.code                    // non-zero if it failed
"on \($(git branch --show-current))"
```

Failing isn't an error unless you say so with `try` (see
[pipeline.md](pipeline.md)); Swift's `do`/`catch` catches it, with the
result in the error:

```swift
do {
    let log = try $(make)        // without `try`, a failure is only in log.status
} catch {
    echo "make failed with \(error.status.code)"
    error.text                   // what it printed before failing
}
```

`catch` catches any runtime error; `error.message` says what happened,
and `error.status` has `code`, `signal` (if one ended it) and `succeeded`.
`catch let e { … }` names it something else.

A command run as a statement only succeeds or fails, as in every shell:
`if make { }`, `make && …`. `try make` makes its failure throw, so
`do { try make } catch { error.status.code }` gets the code, and
`try! make` stops a script if make fails. There's no global `status` or
`$?`; using it is an error that points here.

## Enums and switch

Enums are Swift's: plain cases, raw values, and associated values.

```swift
enum Kind { case file, directory }
enum Level: Int { case low = 1, mid, high }          // mid is 2
enum Result { case ok, failed(code: Int, String) }

Kind.allCases                                       // [file, directory]
Level(rawValue: 2)                                  // mid; nil if there's none
Level.high.rawValue                                 // 3
let r = Result.failed(code: 2, "no such file")
```

`.directory` on its own takes its enum from context, as in Swift: the other
side of `==`, a `case` in a switch over an enum, a parameter or return type.
With nothing to go by (`let k = .directory`) it's an error asking for
`Kind.directory`. Comparing an enum with a String is an error too, pointing
at the case to use instead. Methods and computed properties on enums wait
for types in general.

`switch` takes Swift's patterns: cases with their associated values bound
by `let`, literals, ranges, several patterns to a case, `where`, `_`,
`default`, `fallthrough`, and `break` to do nothing. Every case needs a
statement. Swift checks a switch covers every possibility when compiling;
Swish can only check when it runs, so a switch that matches nothing is an
error then.

```swift
switch r {
case .ok: echo "fine"
case .failed(let code, let why) where code > 1: echo "\(code): \(why)"
case .failed: echo "failed"
}
if case .failed(let code, _) = r { echo "code \(code)" }
```

On the command line, an enum parameter takes a case's name (or raw value),
and `--help` lists them: `pick --kind <file|directory>`. Builtins use enums
too: `ls` gives each entry a `FileType` (`.file`, `.directory`, `.symlink`,
`.other`), so `ls | filter { $0.type == .directory }`, and a job's `state` is
a `JobState` (`.running`, `.stopped`, `.done`, `.cancelled`).

## Types

Swish is statically typed, as Swift is: each entry at the prompt, and a
whole script, is checked before any of it runs, and a type error runs
nothing (see [types.md](types.md)).

```swift
let xs: [Int] = []                  // a type where the value can't say
let t = (name: "x", size: 2.mb)     // a tuple: the anonymous record
let d = ["a": 1, "b": 2]            // a Dictionary, [String: Int]
let port: Int? = nil
port ?? 8080                        // unwrap with ??, if let, ! or ?.
func f() { 42 }                     // no `->`: returns nothing
```

### Protocols and key paths

A struct or enum says which of the builtin protocols it conforms to, and
Swift's rules follow: `==` needs `Equatable`, `<` and `sorted()` need
`Comparable`. An enum without associated values is `Equatable` and
`Hashable` already.

```swift
struct Point: Equatable, Hashable { var x: Int; var y: Int }
enum Level: Int, Comparable { case low, high }

ls | sorted --by size              // a field's name is a key path, checked against FileEntry
files.sorted(by: \.modified).map(\.name)
```

### Any and JSON

`Any` holds anything, and does nothing until it's cast, as in Swift:

```swift
let x: Any = 5
(x as? Int ?? 0) + 1              // as? gives nil if it isn't one
x is String                       // false
let config = from("json", $(cat config.json).lines)
config.server?.port?.int ?? 8080  // each field is a JSON?
config["tags"]?[0]?.string
```

A pipeline can't be a `let`'s value, so parsed JSON kept in a variable comes
from `from` called as a function, as above.

### Throwing

Swift's rules: a function that can fail says `throws`, a call to it needs
`try`, and a `try` needs something to handle what it throws: a `throws`
function, a `do`/`catch`, or the top level of the prompt or a script.

```swift
func build() throws {
    try $(swift build)             // `try $(…)` throws, so build must be `throws`
}
try build()                        // the prompt handles it
func quiet() {
    do { try build() } catch { echo "failed: \(error.message)" }
}
let ok = (try? build()) != nil
```

## Structs and assignment

A struct's values are records whose type is the struct, so they're values
as in Swift (copying one copies it), and they work wherever records do:
tables, `filter`, `select`, `to json`. The type adds what a record doesn't
have: a memberwise init, computed properties, methods and initializers.

```swift
struct Point {
    var x: Int
    var y: Int = 0
    var lengthSquared: Int { x * x + y * y }
    func describe() -> String { "(\(x), \(y))" }
    mutating func move(by d: Int) { x += d; y += d }
}

var p = Point(x: 3, y: 4)       // Point(x: 3, y: 4)
p.move(by: 1)
p.x *= 2
[p, Point(x: 1)] | filter { $0.x > 1 }
```

- **Members are in scope in their bodies**, through `self`, and a member
  can use one declared further down. A parameter or local of the same name
  shadows it; `self.x` still reaches it.
- **`mutating` is checked as in Swift.** A mutating method can only be
  called on a `var` (or part of one), and changes it; any other method
  can't assign to `self`. `let` properties can be set by an `init` and
  never after.
- **Initializers:** without one, a struct gets the memberwise init (every
  stored property in order, except a `let` that already has a value; one
  with a default can be left out). Declaring an `init` replaces it, and an
  `init` must set every stored property.
- **Types are checked** when a value is made and when a property is set:
  `p.x = "a"` fails with `Point.x must be Int, not String`.
- **A struct can be a parameter or return type.** Passing a plain record
  where a `Point` is wanted fails, even if the fields match. Structs can't
  be typed on a command line yet.
- **Assignment reaches into values:** `p.x = 1`, `xs[0] += 5`,
  `r["key"] = v`, `l.end.x -= 1`, with `+=`, `-=`, `*=` and `/=` for
  variables too. The variable must be a `var`.

## Scripts

`swish script.swish a b c` runs a script. It's parsed whole, so a syntax error
anywhere stops it before anything runs; then it runs a statement at a
time, and a runtime error only abandons its own statement, unless it was
under `try!`.

`args` holds the script's arguments. If the script declares `func main`,
it's called with them as its command line, so the script gets flags,
`--help` and completion from `main`'s signature, under the script's name:

```swift
#!/usr/bin/env swish
/// Greets someone.
func main(_ name: String, loud: Bool = false) {
    if loud { echo "HI \(name)" } else { echo "hi \(name)" }
}
```

A `#!` first line is skipped. `#filePath` is the running script's path
(`"<prompt>"` at the prompt), so a script can find files beside it:
`let here = $(dirname "\(#filePath)").text`.

`defer { … }` runs its block when the enclosing block, function or script
ends, however it ends: normally, by `return`, `break` or a thrown error.
Several run last-first. A script's top-level `defer`s run when the script
ends, after `main` and after a `try!` stops it. Nothing leaves a `defer`:
it can't `return`, `break` or `continue`, and whatever throws in it must
be handled there.

```swift
let dir = $(mktemp -d).text
defer { rm -rf $dir }
```

POSIX's `$1` and `$@` would collide with closures' `$0`, `$1`, so there
aren't any.

## Redirects

| Swish | POSIX | Sends |
|---|---|---|
| `> f`, `>> f` | same | output to a file |
| `< f` | same | a file to input |
| `e> f`, `e>> f` | `2> f`, `2>> f` | errors to a file |
| `o+e> f`, `o+e>> f` | `&> f`, `&>> f` | both to a file |
| `e>o` | `2>&1` | errors wherever output goes, as in `cmd e>o \| grep x` |
| `o>e` | `>&2` | output wherever errors go, as in `echo oops o>e` |

They apply left to right, so `> out e>o` puts both in `out` while
`e>o > out` sends only output there. `e>o` and `o>e` must stand alone:
`e>output` writes errors to a file named `output`. POSIX forms, and
numbered descriptors like `3>`, are errors that name the Swish spelling.

## Running a program, not a function

`foreign ls` (or `^ls` for short) runs the program even when a function or
builtin has the name.

## Background jobs

There's no `&`: background work is always a value you hold, a `Job`.

```swift
let build = async swift build     // starts it; `build` is the job
build.state                       // "running", "stopped", "done" or "cancelled"
let page = async $(curl -s example.com)
let html = await page             // waits; gives its Output
try await build                   // waits; throws if it failed, like `try make`
build.cancel()                    // SIGTERM
```

`await` gives the job's `Output`, with its status (and, for `async $(…)`,
its text), and never throws on its own; `try await` throws if the job
failed, as `try` does for any command. An awaited job's statement fails if
the job did, so `await build && echo ok` works.

`jobs` lists the jobs in the background, oldest first: ones started with
`async`, and ones suspended with ^Z. They're values like any other, shown
as a table like `ls`'s records, and their fields (`id`, `command`, `state`,
`pids`, `output`) work with `filter`, `select` and `to json`:

```swift
jobs                              // id  state    command
                                  //  1  running  swift build
jobs | filter { $0.state == .stopped } | select id command
await                             // the most recent job: the ^Z'd vim, say
await jobs[0]                     // another one
jobs.last?.resume()               // carry a stopped job on in the background
```

`await` replaces `fg`: it gives the job the terminal (and the terminal
modes it had when it stopped, so vim comes back as it was), continues it if
it was stopped, and waits. `resume()` replaces `bg`. Both old names are
errors that point to the new ones.

When a background job finishes, or stops because it wants the terminal,
you hear about it just before the next prompt, never in the middle of your
typing: `[1] done  swift build`, `[2] failed (2)  make`. A finished job
stays in `jobs`, shown as done, until then or until it's awaited. Exiting
with jobs in the background asks you to confirm by exiting again.

A job stopped mid-read of the terminal has that read cut short when it's
continued; programs that retry, like vim, less or Python, carry on, while
some (macOS's `cat`) give up. The same happens under bash's `fg`.

`async` runs external commands and pipelines: a Swish function in the
background needs the interpreter to run on more than one thread.
