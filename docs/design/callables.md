# Functions and commands

Status: **design**.

Swish has **one kind of callable with two call syntaxes**. A function is
defined once, and its command-line form is derived from its Swift signature.
Swift's argument labels already are command-line flags.

```swift
func greet(_ name: String, times: Int = 1, loud: Bool = false) -> String { … }

let s = greet("Rak", times: 2)     // expression mode: a Swift call
greet Rak --times 2 --loud         // command mode: the same function
```

## Signature → command line

| Swift signature | Command mode |
|---|---|
| `_ name: String` (unlabeled) | positional argument |
| `times: Int` | `--times 2` or `--times=2`; the string is converted to the declared type, with an error if that fails |
| `loud: Bool = false` | the switch `--loud` |
| `color: Bool = true` | `--no-color` |
| `ignoreCase:` | `--ignore-case` (camelCase becomes kebab-case) |
| `_ files: String...` | the remaining positionals |
| default value | optional flag |
| no default | required; missing ones are reported by name |
| `throws` | non-zero status, which is what `&&`/`\|\|` look at |
| return value | output to the pipeline |

`--` ends flag parsing, so `rm -- --weird-name` works.

**Array parameters take a repeated flag:** `--include a --include b` for
`include: [String]`. There's no comma splitting, so values containing commas
need no escaping, and this matches Unix tools like `grep -e` and `curl -H`.

**A dash followed by a number is a value when it fits.** `calc -5` passes
`-5` if the callable has no short flag named `5` and the next positional
parameter is numeric. Otherwise it's a flag. Externals always receive
their argv verbatim.

Short flags and help text can't be derived from a signature:

```swift
/// Repeats a greeting.
/// - Parameter times: how many times to greet
func greet(_ name: String, @flag("n") times: Int = 1) -> String
```

The doc comment becomes `greet --help`, and the flag metadata drives tab
completion.

## Pipeline input

One parameter can be marked `@input`, and its type decides how the function
streams:

```swift
// Called once per item: a map/filter stage (PowerShell's `process` block).
func where(@input _ item: Value, _ predicate: (Value) -> Bool) -> Value?

// Receives the whole stream: an aggregating stage (PowerShell's `end` block).
func sort(@input _ items: [Value], by key: KeyPath) -> [Value]
```

A per-item function returning `nil` outputs nothing for that item. Outside a
pipeline, the `@input` parameter is an ordinary argument:
`where(x, { $0.size > 1.mb })`.

## Choosing the syntax

- At the start of a statement, `name(` with **no space** is an expression
  (a Swift call), and `name args…` is command mode.
- Method calls (`x.foo()`) are always expression mode.
- **External programs** are callable only in command mode. In expression
  mode they need `$(…)`, so `git(…)` can never secretly spawn a process.

## Name lookup in command mode

1. Swish functions and builtins
2. External programs on `PATH`

`^name` forces the external, so defining `func ls` never makes `/bin/ls`
unreachable. `which name` reports what a name resolves to.

Structured builtins deliberately keep their familiar Unix names and shadow
the tools: a bare `ls`, `ps` or `sort` gives records, so
`ls | where { $0.size > 1.mb }` works out of the box. `^ls` gets `/bin/ls`.

Only names defined with `func` are callable in command mode. A closure
stored in a variable is called in expression mode (`f(x)`). This keeps
command-mode lookup static, which also lets highlighting and completion know
what a name is before it runs.

## Overloads

Expression mode follows Swift's overload rules. Command mode only has
strings to go on, so it picks the overload whose labels match the flags
given, and fails with a list of candidates if more than one fits. There is
never a silent guess.

## Swift-side callables

Builtins, and bridges for imported packages, are ordinary Swift functions
registered with a macro that records their signature at compile time. Swift
has no runtime reflection for function signatures, so a macro is what makes
the derived command-line form possible.

```swift
@SwishExport(input: "item")
func where(_ item: Value, _ predicate: Closure) throws -> Value? { … }
```

The bridge generator for imported packages emits the same registrations, so
library functions get flags, help and completion without anything written
by hand.

## Why not separate `func` and `command` keywords

- A separate keyword forces a choice up front that is often wrong: a helper
  later needs to be a command, or the other way round.
- Imported library functions would never be usable as commands.
- PowerShell's worst gotcha comes from the lack of a real call syntax: its
  functions are command-only, so `Add(1, 2)` passes one array argument.
  Supporting both syntaxes properly rules this out.
