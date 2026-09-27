# Structured pipelines

Status: **design**, nothing here is implemented yet beyond raw byte pipes
between external commands.

Swish pipelines carry values, not text, in the style of PowerShell. The goal
is PowerShell's model (a shell over a runtime's libraries, with objects
flowing between commands and formatting deferred to the end) without its
verbosity or its mistakes at the boundary with native programs.

## Values

```swift
enum Value {
    case nothing, bool(Bool), int(Int), double(Double), string(String)
    case path(FilePath), filesize(Int64), duration(Duration), date(Date)
    case list([Value])
    case record(Record)          // ordered String → Value
    case object(SwishObject)     // a live, bridged Swift value
    case closure(Closure)
}
```

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
2. **`Encodable` → `Value`.** A custom `Encoder` turns any `Encodable`
   value into a record, so most library model types need no bridge code at
   all.
3. **`Mirror` as a fallback** for reading the stored properties of anything
   else, enough for display and `select`.

## Stages and boundaries

A pipeline mixes internal stages (Swish functions and builtins) and external
programs. What flows across each boundary:

| From → to | Carries |
|---|---|
| external → external | A raw fd pipe. Swish never touches the bytes. |
| external → internal | A lazy stream of lines (`String`), or parsed values with `from json`, `from csv` and so on. |
| internal → internal | `Value`s, one at a time. |
| internal → external | Strings and scalars are written one per line, and lists one line per item. Records and objects are an **error** that suggests `to json` or `to text`, rather than a guessed rendering. |

External-to-external must stay raw. PowerShell before 7.4 decoded
native-to-native pipes as text and re-encoded them, which broke binary data
(`curl … | tar x`).

### Streaming

Internal stages are pull-based, synchronous iterators, so no async is
needed in the executor. A stage pulls only what it needs: `ls -r | first 5`
stops walking the tree after five entries. When an internal stage stops
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
  `ls` records carry every field (permissions, inode, owner, …) but show
  `name`, `type`, `size` and `modified`.
- Explicit formatters (`table`, `list`, `to text`, `to json`) override the
  view.
- **Streams are shown progressively.** The display step buffers up to about
  100 rows or 200ms, sizes the columns from that sample, prints it, then
  streams the remaining rows. Later values too wide for their column are
  truncated with `…`. This gives aligned tables for normal output and
  immediate feedback for slow or endless streams.
- **Objects without a view or `Mirror` children** show their type name,
  plus their `description` if they conform to `CustomStringConvertible`,
  with a hint to run `members`.
- **`members`** (PowerShell's `Get-Member`) describes whatever is in the
  pipeline: its type, fields, and for objects, methods and their signatures.
  This is how you find your way around an imported library.

## Errors

- **Fatal errors:** a function that `throw`s stops the pipeline, and the
  statement's status is failure.
- **Per-item errors:** a stage reports a problem with one item (say, one
  unreadable file) to a separate error stream and keeps going. Reported
  errors are values (message, source, the item concerned), rendered by the
  display step and inspectable afterwards. Any reported error makes the
  statement's status a failure, like PowerShell's `$?`.

## Deliberately not copied from PowerShell

- **Verb-Noun names** and aliases to paper over them. Swish uses short names.
- **`-eq`/`-gt` operators.** Swish's two parsing modes let `>` compare in
  expressions and redirect in commands.
- **Implicit output**, where every stray expression in a function becomes
  part of its output. Swish functions output only what they `return`.
- **Single-item collections silently becoming scalars.**
- **Case-insensitivity by default**, and slow startup.
