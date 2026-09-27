# Structured pipelines

Status: **implemented**, except live objects and generated bridges
(milestone 8), paths and durations, and errors as inspectable values.

Swish pipelines carry values, not text, in the style of PowerShell. The goal
is PowerShell's model (a shell over a runtime's libraries, with objects
flowing between commands and formatting deferred to the end) without its
verbosity or its mistakes at the boundary with native programs.

## Values

```swift
enum Value {
    case nothing, bool(Bool), int(Int), double(Double), string(String)
    case filesize(Int64), date(Date)
    case list([Value])
    case record(Record)          // ordered String → Value, with an optional type name
    case function(any Callable)
    // Planned: object(SwishObject), a live bridged Swift value (milestone 8);
    // path and duration.
}
```

Literals: `1.5.mb`, `2.kib` for file sizes; `["name": "x", "size": 1.kb]`
for records and `[:]` for an empty one. Fields are read with `r.name` or
`r["name"]`; lists, strings and records also have a few members like
`count`, `isEmpty`, `keys` and `lines`. File sizes add, subtract, scale and
compare; dates compare, and subtract to seconds.

- **Plain data is the default.** Builtins produce records and lists. They
  display cleanly, convert to JSON, and can be handed to external programs.
- **`.object` exists for library interop.** Values from imported Swift
  packages that aren't plain data stay live, with bridged methods and
  properties.
- **Both expose members the same way.** `where`, `select`, `sort` and field
  access (`$0.size`) work identically on records and objects.
- **There is no table type.** A table is a list or stream of records, and
  the display step decides whether to lay it out as one.
- **Records keep insertion order.** Column order is part of how a command
  presents its output.

### Getting Swift values into Swish

In order of preference:

1. **Generated bridges** (see [callables.md](callables.md)) for functions
   and methods.
2. **`Encodable` → `Value`** (`ValueEncoder` in SwishKit). Structs become
   records named after their type, so views apply; `Date` and `FileSize`
   keep their meaning. Most library model types need no bridge code at
   all. The `ls` and `ps` builtins produce their records this way.
3. **`Mirror` as a fallback** (`Value(reflecting:)`) for reading the stored
   properties of anything else, enough for display and `select`.

## Stages and boundaries

A pipeline mixes internal stages (Swish functions and builtins) and external
programs. What flows across each boundary:

| From → to | Carries |
|---|---|
| external → external | A raw fd pipe. Swish never touches the bytes. |
| external → internal | A lazy stream of lines (`String`), or parsed values with `from json`. |
| internal → internal | `Value`s, one at a time. |
| internal → external | Strings and scalars are written one per line, and lists one line per item. Records are written as the rows they'd display as (the view's columns, no header, no color, nothing cut short), so `ls \| grep x` and `ls \| wc -l` work as they do in other shells. Exact data comes out with `get` or `to json`. Functions have no text form and are an error. |

Redirecting a Swish stage's output to a file (`ls > files.txt`) writes it
as it would be displayed, header included, without color. Its errors
follow its `2>`, so `f 2>/dev/null` silences a Swish function as it would
a program. Only the first and last Swish functions in a pipeline can
redirect their input and output.

External-to-external must stay raw. PowerShell before 7.4 decoded
native-to-native pipes as text and re-encoded them, which broke binary data
(`curl … | tar x`).

### Streaming

Internal stages are pull-based, synchronous iterators, so no async is
needed in the executor. A stage pulls only what it needs: `seq 1000000 |
first 5` reads five lines. (`ls` itself isn't lazy yet; it lists a whole
directory before passing it on.) When an internal stage stops
early and upstream is external, Swish closes the read end and the process
gets `SIGPIPE`, just as it would with `head`.

Per-item versus whole-stream processing is decided by the function's
signature (see `@input` in [callables.md](callables.md)). This replaces
PowerShell's `begin`/`process`/`end` blocks.

## Format at the edge

Commands never format. Only the display step at the end of an interactive
pipeline turns values into text, and only if nothing else consumed them.

- **Views** are registered per type and pick default columns and a layout
  (table for lists of similar records, key/value list for a single record).
  `ls` records carry every field (permissions, owner, dates, path, …) but
  show `name`, `type`, `size` and `modified`; `ls -l` shows them all.
- Explicit formatters (`table`, `list`, `to text`, `to json`) override the
  view. They return lines of text, so their output can go on to external
  programs.
- **Tables fit the terminal.** Wide columns shrink, down to 6 characters;
  if that isn't enough, columns are left off the right and the header ends
  in `…`. Numeric columns are right-aligned. When the output isn't a
  terminal, only the 40-character column cap applies.
- **Streams are shown progressively.** The display step buffers up to about
  100 rows or 200ms, sizes the columns from that sample, prints it, then
  streams the remaining rows. Later values too wide for their column are
  truncated with `…`. This gives aligned tables for normal output and
  immediate feedback for slow or endless streams.
- **Objects without a view or `Mirror` children** will show their type name,
  plus their `description` if they conform to `CustomStringConvertible`,
  with a hint to run `members`.
- **`members`** (PowerShell's `Get-Member`) describes whatever is in the
  pipeline: each type's fields and their types, members like `count`, and
  function signatures. For objects it will list methods too; it's how you'll
  find your way around an imported library.

## Errors

- **Fatal errors:** a runtime error stops the pipeline and the rest of the
  input, and the statement's status is failure.
- **Per-item errors:** a stage reports a problem with one item (say, one
  unreadable file) and keeps going, as `ls nosuch Package.swift` does. Any
  reported error makes the statement's status a failure, like
  PowerShell's `$?` (Swish's `status`). For now they're messages on standard error; making
  them values (message, source, the item concerned) that can be inspected
  afterwards is still to do, as is a way for Swish functions to report them.

## Deliberately not copied from PowerShell

- **Verb-Noun names** and aliases to paper over them. Swish uses short names.
- **`-eq`/`-gt` operators.** Swish's two parsing modes let `>` compare in
  expressions and redirect in commands.
- **Implicit output**, where every stray expression in a function becomes
  part of its output. Swish functions output only what they `return`.
- **Single-item collections silently becoming scalars.**
- **Case-insensitivity by default**, and slow startup.

## Failing commands in `$(…)`

`$(…)` is a call to a throwing function whose `try` is implicit, since every
one would need it: a command that fails inside it is a runtime error, as in
Nushell, because its output is unlikely to be what the rest of the line
expects. The error's status is the command's own.

Swift's other two forms keep their meaning, and work on any expression
that can throw a runtime error, not just `$(…)`:

- **`try?`** is nil instead of an error. nil counts as failure in `&&`,
  `||` and `if`.
- **`try!`** stops a script (`swish script.sw`, or input piped in) with the
  failure's status, where any other error only abandons its statement and
  the script carries on. At the interactive prompt it's a plain error,
  since stopping would mean exiting your shell.
- A bare **`try`** is accepted for readability and changes nothing.

```swift
if let head = try? $(git rev-parse HEAD) { echo "at \(head)" } else { echo "not a repo" }
let editor = (try? $(git config core.editor)) ?? "vi"
try? $(grep -q TODO notes.txt) != nil && echo "still things to do"
let config = try! $(cat ~/.config/tool.json)   // a script can't go on without it
```

As in Swift, `try` covers everything to its right: `try? $(cmd) ?? "vi"` is
nil when `cmd` fails, so a default needs the parentheses above.

A line starting with `$(` is an expression, so these read naturally; `$name`
still starts a command, as in `$EDITOR notes.txt`.
