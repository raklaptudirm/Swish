# Desugaring

Every shell construct in Swish is sugar for Swift. This is the specification:
for each construct, the Swift it means, what that rewrite needs to know, and
what exists today. It follows [direction.md](direction.md) (Swish is Swift
plus shell constructs) and is the table of departures from Swift: anything
not here is Swift.

The rewrite and the library it targets belong to the shell layer, not the
embeddable core ([embedding.md](embedding.md)): the core is Swift only, and
reaches the outside only through its `SwishHost`.

Every shell construct is rewritten now: after checking, the shell's
`Desugarer` turns each into calls to the library below, and the interpreter
only runs Swift (meeting a layer's node, it stops with an error). What runs a
command is still the shell's pipeline machinery, which the library's
`Command` and `Pipeline` hand their words to. See "Where it stands" for what
is left: stages as direct Swift calls where types are known, flattening
statements, and effects.

## How the rewrite works

1. **It runs after checking, on the core tree.** It rewrites Swish's own
   syntax tree, not text, because some choices depend on types (see "What
   needs types"). The result has no shell nodes left: only Swift constructs
   and calls into the library below. A printer from that tree to Swift
   source comes later, for the compile path and `--emit-swift`.
2. **What it produces could be written by hand.** Every form in the table is
   code a person could type in Swish, so each can be tested before the rewrite
   exists, and the rewrite can be read as documentation.
3. **A dynamic form where types aren't known.** When a stage's input or a
   name's type isn't known, the rewrite emits a call that decides at run time
   (`Stage.call(name, words, upstream)`), as the interpreter does today. It is
   the escape hatch, not the common case.
4. **Positions survive.** Each rewritten node keeps the source range of the
   construct it came from, and each library call that can fail carries the
   construct's text (`PipelineNode.source` today), so an error reads in terms
   of what was typed.
5. **Effects are inserted here** (see "Effects").

## The library the rewrite targets

All Swift, in `SwishStandardLibrary`, callable by hand:

| Type | What it is |
|---|---|
| `Command` | A program or a Swift function with its words: `Command("ls", "-la")`, then `external()`, `environment([…])`, `reading`/`writing`/`appending(fd, …)`, `sending(fd, to: other)`, `calling((…))`; run with `run()`, `runQuietly()`, `check()`, `output()`, `start()`, `startCapturing()` |
| `Pipeline` | Commands joined with `\|`, fed a value or not: `Pipeline(from: xs, Command("sorted"))`, run the same ways |
| `Glob`, `Spread` | A command word with an unquoted wildcard (`Glob("*.swift")`), and an unquoted value alone, a word per item (`Spread(files)`); `escapingWildcards(x)` keeps a value's own `*` literal in a pattern |
| `capture { … }` | `$(…)`: the block run with its output gathered, an `Output`; `capture(throwing: true)` under `try` |
| `Status` | What `run()` gives: `code`, `signal`, `succeeded`, and `and`/`or` for chains |
| `Output`, `Job`, `Flow` | What a command gave, a job in the background, items as they come |
| `with(env:)`, `env` | Variables for a block, and the process's environment |
| `importPlugin(name, from:)` | `import Name from path` |

`Command`, `Pipeline`, `Glob`, `Spread` and `Status` are Swift structs in the
shell's prelude (`Library+Shell.swift`); the methods that run them have
Swift bodies, and run where they are called from, so a command finds the
functions in scope there.

## The constructs

"Types?" says whether the rewrite needs the checker's knowledge of types.

### Commands and words

| Shell | Swift | Types? |
|---|---|---|
| `git status -s` (statement) | `await Command("git", "status", "-s").run()`; the sink shows the output and sets the shell's status | no |
| `ls --all` (a Swift function as a command) | `await ls(all: true)`: the words become typed arguments from the declaration | yes: the declaration |
| `ls $dir *.swift` (words with runtime parts) | `await Words.call(ls, [.interpolation(dir), .glob("*.swift")])`: the dynamic form, converting words to arguments at run time | no |
| `where { $0.size > 1.mb }` (a closure word) | the closure, as an argument | no |
| `^name args` | `Command("name", args)`: a program, skipping functions and builtins of that name | no |
| `cd`, `exit`, `exec`, `source`, `umask`, `ulimit`, `which`, `run` | Swift functions, not sugar: library functions that take the shell through `ShellContext` | n/a |

How a name is read, command or expression, stays a parsing rule, not a
rewrite: a name that isn't a known variable at the start of a statement is a
command (the parser tracks names today).

### Substitution and failure

| Shell | Swift |
|---|---|
| `$(echo hi; ls)` | `await Shell.capture { echo("hi"); ls() }`: the block runs with this task's output redirected, giving an `Output` |
| `$(…)` failing | it doesn't throw: the `Output`'s `status` says how it ended, as with `Result` |
| `try $(make)`, `try make` | `try (await …).get()`: failure throws |
| `try? $(…)`, `try! $(…)` | `try? (await …).get()`, `try! (await …).get()` |

### Pipelines

`a | b | c` is a chain whose stage kinds depend on what flows in:

| Stage | Swift | Types? |
|---|---|---|
| first value `xs \| …` | `Pipeline(xs)` (a list or sequence flows as its items) | no |
| a function with an `@Input` list | the function called with the items collected | yes |
| a function with an `@Input` item | the function called per item, results flowing on | yes |
| a `Flow` method (`filter`, `map`, `compactMap`, `prefix`) | the method on the stream, lazily | yes |
| a method of the collected items (`xs \| max`) | `xs.max()` | yes |
| a method of each item (`names \| uppercased`, `points \| describe`) | `names.compactMap { $0.uppercased() }` | yes |
| a program (`… \| grep x`) | `Command("grep", "x")` fed the stream's text | no |
| unknown input type | `Stage.call(name, words, upstream)`: the dynamic form | no |

The last stage's sink shows the result for a person (the table or the list)
when it ends a statement, writes text for a program when a program follows,
and gives the values when a pipeline is an expression.

### Redirects, environment, chains

| Shell | Swift |
|---|---|
| `cmd > f`, `>> f`, `< f` | `Command(…).redirect(.stdout, to: f, append: false)` and the like |
| `2>&1`, `e>o` | `.redirect(.stderr, to: .stdout)`; modifiers apply in the order written |
| `X=1 cmd` | `with(env: ["X": "1"]) { cmd }` |
| `env.X`, `env["X"]` | `Environment["X"]` (a `String?`) |
| `env.X = "v"`, `env.X = nil` | `Environment["X"] = "v"`, `= nil` |
| `$name` | `name` if a variable is in scope, else `Environment["name"]` |
| `a && b`, `a \|\| b`, `a && b \|\| c` | `Chain` over the statuses, run left to right on exit status: `await Shell.chain({ a }, and: { b }, or: { c })` |
| `if grep -q x f { … }` | `if await grep(…).succeeded { … }`; `while` the same |
| `for line in $(cmd)` | `for line in (await …)`: iterating an `Output` goes by line, already |

### Jobs

| Shell | Swift |
|---|---|
| `async cmd`, `async $(cmd)` | `Job.start(cmd)`, `Job.start { $(cmd) }` |
| `async f(x)`, `async { … }` | `Job.start { await f(x) }`: a task, the same handle |
| `await job` | `await job.value`: joining a handle. `await f()` of a call is Swift's `await`. Which one is decided by the operand's type |
| `jobs`, `job.cancel()`, `job.resume()` | `Shell.jobs` and methods on `Job` |

`await job` is the one place `await` means something other than Swift's: it
joins a handle, as `await task.value` does. It's listed here so it is a
decision, not an accident.

### The prompt

| Shell | Swift |
|---|---|
| a top-level expression statement | `Shell.display(expression)`: shown as `debugDescription` shows it, or a table for records. Only at the top level; in a function a bare value is discarded, as in Swift |
| a command or pipeline statement anywhere | its sink writes to this task's standard output |

## What needs types

Four things, all answered by the checker the interpreter already uses:

1. **A function's declaration**, to turn words into typed arguments
   (`ls --all` to `ls(all: true)`), including defaults, flags and labels.
2. **What flows into a stage**, to choose among the stage kinds above.
3. **A closure's effect**, for the overloads that take it (see "Effects").
4. **Whether a name is a variable**, for `$name`.

Anything the checker can't tell becomes the dynamic form, which does today's
run-time lookup. It means a fully untyped script still works, and a typed one
rewrites to direct calls.

## Effects

Only shell constructs bring implicit effects, and only an `await`:

- **Sources:** a command, a pipeline, `$(…)`, and a call to an implicit-async
  function. Each waits on a process or a stream.
- **The rewrite** computes, over the call graph, which functions and closures
  contain a source outside their nested closures, makes those `async`, and
  inserts `await` at calls to them. After it, only plain Swift effect rules
  remain: nothing else in the checker or the interpreter knows about "implicit".
- **A function with an explicit `await`, `try` or `throw`** is declared as in
  Swift; it can also contain sources, which add nothing to it.
- **Closures** get their effect the same way, so a closure containing `$(…)`
  is an async closure, and passing it to `map` selects the async overload.
- **`throws` is never inferred:** `$(…)` doesn't throw, and `try` is written.

## What is not sugar

These stay as named departures:

- **The command-or-expression rule** at the start of a statement.
- **The statement sink and the prompt's display,** which Swift has no
  equivalent of.
- **`await job`** joining a handle.
- **`select`'s type,** until Swift can express it with parameter packs.
- **`JSON` as a stand-in type,** until the bridge can call dynamic members.

## The hooks the rewrite replaces

A Racket language replaces the edges of its grammar (`#%app`, `#%top`,
`#%datum`). The same edges are what this rewrite targets: a name that isn't
bound at the head of a line is looked up as a command (`#%top`), the words
after it are call arguments (`#%app`), and `$name`, `$(…)` and `async` are
the shell's own forms. Naming them as the rewrite's input, rather than
rediscovering them in each construct, keeps the table above complete
(frontend.md, "The grammar's hooks, named").

## Order of work

Each step removes a path from the interpreter, and the existing tests are
the net: the behavior doesn't change. (Steps 2 and part of 3 are done; see
"Where it stands" for why the status design moves ahead of the rest.)

1. **The library types, by hand.** `Command`, `Pipeline`, `Words`,
   `Environment`, `Shell.capture`, `Shell.chain` in `SwishStandardLibrary`,
   with tests that call them directly, so every desugared form is runnable
   before anything rewrites to it.
2. **A rewrite pass with a printer for tests,** printing the core tree as
   Swift. It starts empty.
3. **The simplest constructs:** `X=1 cmd` to `with(env:)`, `env.X`, `$name`,
   `try` on commands, `&&` and `||`.
4. **Redirects and words.**
5. **Substitution and command statements,** with the effects insertion: the
   largest step, since this is where `async` appears.
6. **Pipelines,** the type-directed stages and their dynamic form.
7. **Jobs and `async`/`await`,** together with the async plan
   ([async.md](async.md)); its step 3, effects in the checker, is this
   document's "Effects".
8. **Flatten statements.** Today every expression statement is a `Chain` of
   `Unit`s joined by `&&`/`||` with an exit status, because a statement was a
   command first. With command chains now library calls, `Unit`'s cases hoist
   into `Statement`, `Chain` is deleted, statements stop returning an `Int32`,
   and the shell records the status of command statements per task
   ([boundaries.md](boundaries.md), the `chain` and `status` groups).
9. **Delete the interpreter's shell nodes** once nothing produces them.

Golden tests print each construct's desugaring; differential tests later
compile the printed Swift with `swiftc` and compare it with the interpreter.

## Where it stands

- **Every construct is rewritten.** `$name`, words (`Glob`, `Spread`,
  interpolations, `~` as `env["HOME"]!`), redirects, `X=1`, `^name`,
  pipelines, `$(…)` (`capture`), `try` on commands (`check()`), `async`
  (`start()`, `startCapturing()`), `exit` (a builtin run as a command),
  `import`, chains and conditions. The shell's nodes only check themselves;
  `Desugarer` replaces each, and the interpreter has no way left to run one.
- **What the checker decided travels with the stage:** `checked(StageHint(…))`
  says what a stage's name is given what flows in (a method of the sequence,
  of each item, a Swift member, or a function or program), which overload a
  call takes, and why a word wasn't an expression. A pipeline written by hand
  has no hint, and the shell looks: a method of the sequence, then a Swift
  member of the items collected, then a function or program.
- **Chains, and flattened statements (step 8):** the core has no chains: a
  statement is an expression, an `if`, a loop or a `switch`, and a condition
  is a Bool. `&&` and `||` joining commands are the shell's: its plug-in
  reads them (`CommandChainExpr`), and they are `a.runQuietly().and { … }.or
  { … }` over `Status`, a Swift expression among them its
  `exitStatus(of:)` (`x > 1 && echo big`, so `false || sh -c 'exit 3'` ends
  with 3, as in a shell). A condition asks whether that `succeeded`; `if try?
  build()` asks whether the `try?` caught nothing.
- **Status:** statements don't give one. The interpreter tells the host each
  statement as it finishes (`statementFinished`), and the shell keeps its
  status from that: an expression statement's value (`false` fails, a
  command's `Status` is how it ended), a per-item error (`ls` of a missing
  path) making it a failure, anything else succeeding. An `if`, a loop, a
  `switch` or a `do` is what last ran in it, and succeeds if nothing did.
- **Printed:** `SwiftPrinter` shows the rewrite, as `DesugarTests` pins:
  `Pipeline(Command("ls"), Command("sorted").calling((by: \.size))…).run()`.

Left:

- **More stages as direct Swift calls.** Done for the kind that is exactly
  a call: a statement's pipeline fed a value, each stage a Swift member of the
  collected items or of the one value, with Swift's arguments or none.
  `[3, 1, 2] | sorted | prefix(2)`… is `displayItems([3, 1, 2].sorted())`, and
  `"a b" | split(separator: " ")` is `displayItems("a b".split(separator: " "))`:
  `displayItems` is the statement's sink, which shows items one a line or as a
  table, as a pipeline's end does. A test runs pipelines both ways and
  compares what they show. Left as `Pipeline`: stages that work item by item
  (`map`, `filter`, `prefix` on a `Flow`, a method of each item), which
  stream, so a direct call would change when side effects happen; the
  prelude's methods; functions and programs; and words to convert
  (`sorted --by size`), which bind as a command line does.
- **Effects** (`await` insertion) wait for the async interpreter: nothing
  awaits yet, so there is nothing to insert.

## Open questions

- **Function values and implicit effects.** A function made async only by
  shell constructs is called with no `await`, but a value of its function type
  (`let f = build`) loses that. Either its type carries an "implicit" mark so
  `f()` needs no `await`, or calling through a value needs one. The first is
  friendlier to scripts, the second simpler.
- **Redefinition at the prompt** of a function from sync to async while
  callers exist: an error, or re-check the callers.
- **Where `Shell.status` lives** once tasks are concurrent: per task, which
  `$?`-like use after `await` suggests.
- **Whether `Command` runs a Swift function and a program the same way,** so
  `ls` and `^ls` differ only in which they resolve to, or are two types.
