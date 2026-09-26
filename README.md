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

## Milestones

1. ✅ REPL, PATH lookup, pipes, process groups, `^C`/`^Z`, `fg`/`jobs`, `cd`/`pwd`/`exit`
2. Redirections (`>`, `>>`, `<`, `2>&1`), globbing, `;`/`&&`/`||`
3. Full job control: `&`, `bg`, per-job terminal modes, `SIGCHLD` notifications
4. The language: `let`/`var`, literals, `if`/`for`/`func`, closures, `\(…)`, `$(…)`
5. Structured builtins (`ls`, `ps`, `where`, `sort`, `from json`) and table rendering
6. Line editor: persistent history, completion, highlighting, multi-line wrapping
7. Plugin ABI in SwishKit + `@SwishExport` macro
8. `import Package from "url"`: SwiftPM resolution, generated bridges, cached dylibs
