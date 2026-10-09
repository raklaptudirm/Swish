# Direction

Swish is meant to become a **full-power, batteries-included Swift
interpreter**, with the command line added as seasoning: you can write real
Swift in it, and the shell conveniences sit on top. This note records the
decisions that follow from that, so the other designs can lean on them.

## Swish is Swift, plus shell constructs

A script that uses no shell construct (`$(…)`, a bare command, a pipeline, a
redirect) is valid Swift and means what it means in Swift. Swish takes
freedoms **only on the shell constructs**:

- **`$(…)` is implicitly awaited, and its failure is captured**, as if it were
  wrapped in a `Result`: it gives an `Output` whose `status` says how the
  command ended, and doesn't throw. `try $(…)` opts into throwing on failure.
  Nothing else in the language is implicit. User-written `try`, `throw`,
  `await`, `throws` and `async` follow Swift's rules.
- **An effect that comes only from a shell construct is inferred.** If the
  only wait in a function is the implicit `await` of `$(…)` (or a command),
  the function is `async` without saying so, and its callers needn't mark the
  call, since taking the shell construct out would take the effect out. A
  function that also has an explicit `await`, `try` or `throw` is declared as
  in Swift; so is a function that uses `try $(…)`, whose `try` is written.

Anything Swish accepts that Swift would reject is a deliberate, documented
seasoning, like these.

The shell constructs are **sugar for Swift**: each rewrites into ordinary
Swift calls on a library in the standard library, after checking. What each
means, and what that needs, is in [desugaring.md](desugaring.md), which is
also the table of every departure from Swift.

## An embeddable core

The interpreter is also a library: an app links it, registers Swift
functions and values, and runs scripts, with no shell, terminal or process
access unless the host grants it. That core is Swift only, with the shell and
its syntax as a layer over it. See [embedding.md](embedding.md), and [boundaries.md](boundaries.md) for the
line between the core and the shell, what crosses it today and how each
crossing exits.

## The engine is a hybrid

The interpreter (the parser, the checker, the tree-walking evaluator, the
bridge from symbol graphs) grows to take the language and everyday scripts.
The real Swift compiler takes the heavy cases: generics-heavy code, imported
packages, speed. It already does for `import Tools from path`, which builds a
package and loads it. A function compiled this way is a Swift function like
any other bridged one, including an `async` one, which is why concurrency
([async.md](async.md)) follows Swift's model and not one of its own.

## Not decided

- Where the line between interpreted and compiled code falls, and whether a
  cell can be marked to be compiled.
- When generics, protocols and extensions of your own types arrive; they are
  what the interpreter's reach most depends on.
