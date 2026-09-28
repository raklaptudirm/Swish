# Using Swift packages as they are

Status: **planned**, as phase 5 of [static types](types.md). It replaces
"typed plugins" there and the old milestone 9 (URLs, versions, bridges).

Any Swift package, and the SDK's modules, used from Swish with nothing
written for Swish: no `@SwishExport`, no wrapper package.

```swift
import Foundation
let url = URL(string: "https://swift.org")!
url.host                                   // "swift.org"
url.appendingPathComponent("docs")          // a URL: a live Swift value

import Yams from "https://github.com/jpsim/Yams"
let config = try Yams.load(yaml: $(cat config.yml).text)
```

`@SwishExport` stays: it's the way to shape a command line (`@Flag`,
`@Input`, doc comments as `--help`) for a package written for Swish.

## Why glue is still compiled

Swift can read a value's fields at run time (`Mirror`), but it can't call a
function or method by name. So calling Swift from an interpreter takes
compiled glue: a thunk per function that converts arguments, calls it and
converts the result back. Swish writes and compiles that glue itself.

## How

1. **Resolve and build.** `import Name from "url"` (or a path, or an SDK
   module with no `from`) resolves the package with SwiftPM, pinned in a
   lock file beside the script or in the shell's state directory, and
   builds it.
2. **Read its declarations.** `swift package dump-symbol-graph` (for
   packages) or `swift-symbolgraph-extract` (for SDK modules) gives every
   public declaration with its full Swift signature: parameters, labels,
   generics and constraints, `throws`, `async`, doc comments. The checker
   loads these as it loads the prelude, so calls are checked against
   Swift's real signatures, and `help` and completion know them.
   Both tools come with the Command Line Tools. A graph can be large
   (Foundation's is 44 MB of JSON), so it's read once into a compact index,
   cached beside the built package, and looked up by name as names are used.
3. **Generate glue for what's used.** After checking, the shell knows each
   declaration the program touches, with concrete generic arguments
   (`JSONDecoder().decode(Config.self, from:)`). It writes a Swift file
   with a thunk for each, like the ones `@SwishExport` generates, and
   compiles it into a dylib against the package.
4. **Cache it.** Dylibs are cached by the symbols they bridge, the
   package's version and the compiler's. The first use of an API pays one
   compile (a second or two, with a progress hint as for "Building…");
   after that it loads at once, in any shell.

## Values across the boundary

- **Values Swish has convert:** numbers, `String`, `Bool`, `Date`,
  arrays, dictionaries, optionals, tuples, and enums without associated
  values (as Swish enums of the same name and cases).
- **Everything else is a live object:** a boxed Swift value with its real
  Swift type (`URL`, `Data`, `Yams.Node`). Its properties and methods are
  bridged on demand like any other declaration, and it passes back into
  Swift unchanged. An `Encodable` one becomes a record with `to json` or
  `select`; a value type is copied as Swift copies it.
- **Swish values into Swift generics:** a Swish struct crosses as a
  record, so it can be `Codable` data; it can't conform to arbitrary Swift
  protocols.
- **Closures:** a Swish closure passed where Swift wants one is wrapped by
  the thunk, so `swiftArray.map { … }` works.

## Not at first

`inout` parameters, operators, protocols with associated types as values
(`some Collection`), subclassing Swift classes from Swish, and async
beyond waiting for it to finish.
