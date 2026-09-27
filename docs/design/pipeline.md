# Structured pipelines

Status: **implemented**, except generated bridges (milestone 9)
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
    case output(CommandOutput)   // what $(…) and await give: text, lines and status
    case enumValue(EnumValue)    // a case of an enum: .directory, .failed(code: 2)
    case object(any SwishObject) // a live value with its own members: a Job, and later
                                 // bridged Swift objects (milestone 8)
    case function(any Callable)
    // Planned: path and duration.
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
- **An object shows its data as fields.** `SwishObject.fields` is a record
  of its members that aren't methods, by default; tables, `select`, `list`
  and `to json` use it, so `jobs` is a table like `ls`. An object that
  isn't data, like an enum type, returns nil and shows as its description.
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
- **A bare value shows its `debugDescription`**, as Swift's `debugPrint`
  would: `let r = $(echo hi); r` shows `Output(text: "hi", status: …)`,
  a string shows quoted and a case with its type (`FileType.directory`).
  A function called as a command shows its result as a pipeline's output
  would (a list an item per line), since that's what a command's output is.
  Interpolation, commands and pipelines use `description`, the plain text,
  and a list of records is still a table. A bare record shows its debug
  form too (`Point(x: 3, y: 4)`); a command's record result is a key/value
  list. A job on its own reads as `jobs` announces it: `[1] running  make`.
  One that doesn't fit the terminal is broken over lines as you'd format
  it in Swift, and a string of several lines inside it (an Output's text)
  is a `"""` block.
- **Color is sparing.** It marks what matters and separates parts; the rest
  is plain. Values use the input highlighter's colors (strings, numbers and
  `nil`, type names); headers, keys and help sections are bold; errors are
  red; in tables, directories are blue and jobs are colored by state. Only
  terminals get color, and `NO_COLOR` or `TERM=dumb` turns it off.
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
  PowerShell's `$?`. For now they're messages on standard error; making
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

## Failing commands and `try`

A command only reports how it went, whether it runs as a statement or is
captured by `$(…)`; failing isn't an error. `try` makes it one, as it
marks the place where something can throw in Swift:

| | Plain | `try` | `try?` | `try!` |
|---|---|---|---|---|
| `make` | sets success or failure, for `&&`, `\|\|` and `if` | throws on failure | (a syntax error: it has no value) | stops a script on failure |
| `$(make)` | its `Output`, failure or not: check `.status` | throws on failure | nil on failure | stops a script on failure |

The error `try` throws carries the command's status and, for `$(…)`, its
text, and `do`/`catch` catches it:

```swift
do {
    let log = try $(make)
} catch {
    echo "make failed with \(error.status.code)"
    error.text                            // what it printed before failing
}
if let head = try? $(git rev-parse HEAD) { echo "at \(head)" } else { echo "not a repo" }
let editor = (try? $(git config core.editor)) ?? "vi"
let config = try! $(cat ~/.config/tool.json)   // a script can't go on without it
```

`try` covers everything to its right, as in Swift, including the `$(…)` in
a command's arguments (`try echo $(cmd)`); `try? $(cmd) ?? "vi"` is nil
when `cmd` fails, so a default needs the parentheses above. It doesn't
reach into closures or function bodies, which decide for themselves.

`try?` and `try!` also catch other runtime errors, like an index out of
range or division by zero. Those always throw, with or without `try`:
they're bugs rather than outcomes. `try!` stops a script (`swish
script.sw`, or input piped in) with the failure's status, where any other
error only abandons its statement; at the prompt it's a plain error.

Without `try`, a failure is easy to miss: outside a repository,
`let head = $(git rev-parse HEAD)` is empty text with
`head.status.succeeded == false`, and the script carries on. That's the
trade for `try` meaning one thing everywhere.

A line starting with `$(` is an expression, so these read naturally; `$name`
still starts a command, as in `$EDITOR notes.txt`. `$(…)` gives an
`Output`, a collection of lines that is its text where a String is
wanted: see [syntax.md](syntax.md).
