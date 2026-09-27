# Shell syntax

Status: **implemented**, except `async`/`await` (milestone 3).

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

## Status

`status` describes how the previous statement ended: `status.code` (nil if
a signal ended it), `status.signal` (nil otherwise) and `status.succeeded`.
Reading it is a statement too, so read it once into a variable to use more
than one field. POSIX's `$?` is an error that names `status.code`.

## Scripts

`swish script.sw a b c` runs a script. It's parsed whole, so a syntax error
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

Planned for milestone 3. There's no `&`: background work is always a value
you hold.

```swift
let build = async swift build   // starts it; `build` is the job
await build                     // waits; gives its status
let page = async $(curl -s example.com)
let html = await page           // waits; gives its output
build.cancel()
```

^Z still suspends whatever is in the foreground, and `jobs`, `fg` and `bg`
manage it. At first `async` runs external commands and pipelines only: a
Swish function in the background needs the interpreter to run on more than
one thread.
