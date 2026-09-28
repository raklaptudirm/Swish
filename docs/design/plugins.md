# Plugins

Status: **implemented** for local packages (`import Tools from "./Tools"`).
Packages that don't use SwishKit, from URLs or the SDK, are planned in
[swift-interop.md](swift-interop.md).

A plugin is a Swift package that depends on SwishKit and marks what it
exports. `import` builds it, loads its library into the shell, and its
functions become commands like any `func` declared in Swish: the same
command line, `--help`, completion and streaming.

```swift
import SwishKit

/// Greets someone.
/// - Parameter times: how many times to greet
@SwishExport
public func greet(_ name: String, @Flag("n") times: Int = 1, loud: Bool = false) -> [String] { … }

@SwishExport
public func longest(@Input _ lines: [String]) -> String? { … }

public enum Level: String, CaseIterable, SwishEnum { case low, high }

@SwishObject
public final class Counter {
    public private(set) var total = 0
    public func add(_ amount: Int = 1) -> Int { … }
}
```

```swift
import Tools from "~/code/tools"
greet Rak -n 2
ls | get name | longest
let c = counter("x"); c.add(5); c.total
Tools.volume(.high)
```

[`Examples/Tools`](../../Examples/Tools) is a complete one.

## Marking exports

- **`@SwishExport` on a function** generates a description of it:
  parameters with labels, types, defaults, `@Flag` and `@Input`, and the
  doc comment's summary and `- Parameter` lines. It also generates a thunk
  that converts the shell's arguments and the result. It's the same
  metadata a Swish `func` has, so everything derived from a signature
  works the same.
- **`@Flag("n")` and `@Input` are property wrappers** that pass the value
  through unchanged. Swift allows wrappers on parameters, so the Swift
  signature reads like the Swish one, and the function stays callable from
  Swift.
- **Enums conform to `SwishEnum`** (with `CaseIterable`), and that's all:
  default implementations read the cases at run time, and raw `Int` or
  `String` values come along. This isn't a macro because Swift won't let
  one macro attach to both functions and types when it adds conformances.
  An enum with associated values can't be exported yet.
- **Classes get `@SwishObject`**, which adds a `SwishObject` conformance.
  Public properties and methods become members. Properties show as fields
  in tables and in a bare value's form (`Counter(total: 6, name: "x")`).
  Methods are functions (`c.add(5)`).
- **Results can be any of these:** a convertible value (`Int`, `String`,
  `[T]`, `T?`, `Date`, `FileSize`, `Value`, a `SwishEnum`), an object, or
  any `Encodable` data, which becomes records the way `ls` builds its own.
  Parameters must be convertible values or exported objects.
- **Defaults:** literal ones (`1`, `"x"`, `false`, `[1, 2]`) are filled in
  by the shell and shown in `--help`. Others (`Date()`, `.low`) are left
  out by the shell and computed by Swift; `--help` shows their source.

### Why there's no list of exports

A plugin could list its exports in one place, as `#swishPlugin(greet,
longest)`. But Swift can't refer to a function with a property-wrapped
parameter as a value (`let f = longest` is ambiguous), so that list
couldn't name functions that use `@Flag` or `@Input`.

Instead each `@SwishExport` also defines a C symbol, `swish_export_greet`,
that returns its description. On import the shell lists the library's
symbols with that prefix (`nm -gU`) and calls each one. Enums are learned
from the parameters that use them. There's nothing to keep in sync, and a
typo can't leave something out.

## Loading

1. **Resolve the path.** `~` is expanded. A relative path starts from the
   script's directory, or from the working directory at the prompt.
2. **Build.** `swift build -c release --product Name` builds a dynamic
   library, `libName.dylib`. If the library is newer than the manifest and
   everything under `Sources/`, the build is skipped: asking SwiftPM takes
   a second or two even when there's nothing to do. Build errors are shown
   as the compiler's `error:` lines.
3. **Load.** `dlopen` the library and call each export symbol. The plugin
   links SwishKit as `@rpath/libSwishKit.dylib`, the install name the
   shell's own copy has, so dyld uses the one already loaded, and a Swift
   type means the same thing on both sides. A plugin whose objects aren't
   the shell's `NativeFunction` loaded a second copy, and is refused.
4. **Check the ABI version** each export was built with. SwishKit is built
   with library evolution, so it can grow without breaking plugins; the
   version only changes for a break it can't absorb.
5. **Register.** Each function is bound by name. A name that's already a
   function gets another overload if the signature differs (so a plugin's
   `count` can sit beside the builtin), and the import fails if it's the
   same. Nothing is bound if anything clashes. The module name is bound to
   a value whose members are its functions and enums: `Tools.greet("Rak")`.

Importing the same package again does nothing. A library can't be
unloaded from a running Swift process, so picking up changes means
starting a new shell.

A script is parsed whole before it runs, so functions an `import` brings
aren't known when the script is parsed. After an `import`, calling an
unknown name (`greet("Rak")`) is left for run time instead of being a
syntax error; command syntax (`greet Rak`) never needed to know.

## Not yet

- Packages from URLs, pinned versions, and a cache of built libraries
  (milestone 9).
- Generated bridges for packages that don't depend on SwishKit (milestone 9).
- `async` functions, variadic parameters, generic functions, and enums with
  associated values.
- Two exports with the same name in one plugin (their symbols collide).
- Records as parameters (decoding into `Decodable` structs).
