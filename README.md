# Swish

An interactive shell with a Swift-flavored language, structured pipelines, and
(eventually) the ability to `import` Swift packages.

```sh
swift build
.build/debug/swish            # interactive
.build/debug/swish -c 'ls | wc -l'
scripts/test.sh               # unit tests + pty-driven job-control tests
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
2. Redirections (`>`, `>>`, `<`, `2>&1`), globbing, `;`/`&&`/`||`
3. Full job control: `&`, `bg`, per-job terminal modes, `SIGCHLD` notifications
4. The language: two-mode parsing, `let`/`var`, literals, `if`/`for`/`func`, closures, `\(…)`, `$(…)`
5. Callables: command-line binding derived from signatures, `@input` streaming, lookup order and `^name`, `--help`
6. Structured data: records, objects, `Encodable` → `Value`, views and the display step,
   the error stream, `members`, builtins (`ls`, `ps`, `where`, `select`, `sort`, `from`/`to json`)
7. Line editor: persistent history, completion from signatures, highlighting, multi-line wrapping
8. Plugin ABI in SwishKit + `@SwishExport` macro (reusing the callable metadata from 5)
9. `import Package from "url"`: SwiftPM resolution, generated bridges, cached dylibs
