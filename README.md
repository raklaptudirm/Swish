# Swish

An interactive shell with a Swift-flavored language, structured pipelines, and
(eventually) the ability to `import` Swift packages.

```sh
swift build
.build/debug/swish            # interactive
.build/debug/swish -c 'ls | wc -l'
scripts/test.sh               # unit tests + pty-driven job-control and editor tests
```

## Layout

| Path | What |
|---|---|
| `Packages/SwishKit` | `Value` and, later, the plugin API. A separate package so it links as a **dylib** shared by the shell and every compiled plugin. |
| `Sources/CShim` | `posix_spawn` with process groups and terminal handoff, plus the wait-status macros Swift can't import. |
| `Sources/SwishCore` | Tokenizer/parser, pipeline execution, job control, builtins, line editor. |
| `Sources/swish` | The executable. |

## Design

- [Structured pipelines](docs/design/pipeline.md): values instead of text,
  boundaries with external programs, formatting at the end, errors
- [Functions and commands](docs/design/callables.md): one callable, with a
  Swift call syntax and a command-line syntax derived from its signature

## Milestones

1. ✅ REPL, PATH lookup, pipes, process groups, `^C`/`^Z`, `fg`/`jobs`, `cd`/`pwd`/`exit`
2. Redirections (`>`, `>>`, `<`, `2>&1`), globbing (✅ `;`/`&&`/`||`)
3. Full job control: `&`, `bg`, per-job terminal modes, `SIGCHLD` notifications
4. ✅ The language: two-mode parsing, `let`/`var`, literals and operators, lists, ranges,
   `if`/`else`, `for`/`while`/`break`/`continue`, `func`, closures, `\(…)`, `$name`/`$?`, `$(…)`,
   multi-line input
5. ✅ Callables: command-line binding derived from signatures, `@input` streaming,
   `@flag` short flags, `--help` from doc comments, overloads, `^name` and `which`
6. ✅ Structured data: records, file sizes and dates, `Encodable` → `Value`, views and the
   display step, per-item errors, `members`, builtins (`ls`, `ps`, `where`, `select`, `get`,
   `sort`, `first`, `count`, `reverse`, `from json`, `to json`/`to text`, `table`, `list`)
   - still to do: live objects (with 8), errors as values, paths and durations, lazy `ls`
7. ✅ Line editor: persistent history (`$SWISH_HISTORY`, default `~/.swish_history`) with
   prefix search on ↑ and `^R`; Tab completion of commands, flags from signatures, `$`
   variables and paths; highlighting from the parser; multi-line editing and wrapping
8. Plugin ABI in SwishKit + `@SwishExport` macro (reusing the callable metadata from 5)
9. `import Package from "url"`: SwiftPM resolution, generated bridges, cached dylibs
