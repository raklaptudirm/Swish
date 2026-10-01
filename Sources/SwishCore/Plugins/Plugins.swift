import Foundation
import SwishKit

/// `import Tools from "path"`: builds a Swift package that uses SwishKit,
/// loads its library, and brings in every `@SwishExport` function, which
/// then works like a `func` declared in Swish.
extension Shell {
    func importPlugin(_ name: String, from path: String) throws {
        let package = resolve(path)
        if let existing = plugins[name] {
            guard existing == package else {
                throw RuntimeError("import \(name): already imported from \(existing)")
            }
            return // Loaded once; it can't be reloaded without restarting.
        }
        guard FileManager.default.fileExists(atPath: package + "/Package.swift") else {
            throw RuntimeError("import \(name): no Swift package at \(package) (no Package.swift)")
        }
        let library = try build(name, at: package)
        let functions = try load(name, from: library)
        try register(name, functions)
        plugins[name] = package
    }

    /// `~` and paths relative to the script, or at the prompt to the
    /// working directory.
    private func resolve(_ path: String) -> String {
        var path = path
        if path == "~" || path.hasPrefix("~/"), let home = env("HOME") {
            path = home + path.dropFirst()
        }
        let base = scriptDirectory ?? FileManager.default.currentDirectoryPath
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: base, isDirectory: true))
        return url.standardizedFileURL.path
    }

    // MARK: Building

    /// Builds the package's `name` product, a dynamic library, returning
    /// its path. SwiftPM only rebuilds what changed, so an import of a
    /// package that's up to date is quick.
    private func build(_ name: String, at package: String) throws -> String {
        let built = package + "/.build/release/" + dynamicLibraryName(name)
        if isUpToDate(built, package: package) { return built }
        let showProgress = interactive && isatty(STDERR_FILENO) != 0
        if showProgress { writeAll(STDERR_FILENO, "Building \(name)…".styled(Style.dim)) }
        defer { if showProgress { writeAll(STDERR_FILENO, "\r\u{1B}[K") } }

        let arguments = ["build", "-c", "release", "--package-path", package, "--product", name]
        let result = try runSwift(arguments)
        guard result.status == 0 else {
            // The compiler's errors are what's useful; SwiftPM's progress isn't.
            let lines = result.output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            let errors = lines.filter { $0.contains("error:") }
            let shown = (errors.isEmpty ? Array(lines.suffix(20)) : errors).joined(separator: "\n")
            throw RuntimeError("import \(name): the package didn't build:\n\(shown)")
        }
        // SwiftPM links `.build/release` to the platform's directory; asking
        // it costs another second, so only when that's missing.
        var library = built
        if !FileManager.default.fileExists(atPath: library) {
            let binPath = try runSwift(["build", "-c", "release", "--package-path", package, "--show-bin-path"])
            library = binPath.output.trimmingCharacters(in: .whitespacesAndNewlines) + "/" + dynamicLibraryName(name)
        }
        guard FileManager.default.fileExists(atPath: library) else {
            throw RuntimeError("import \(name): the package has no dynamic library named \(name); declare .library(name: \"\(name)\", type: .dynamic, targets: [\"\(name)\"])")
        }
        return library
    }

    /// Whether `library` is newer than the package's manifest and sources,
    /// so the import can skip asking SwiftPM, which takes a second or two
    /// even when there's nothing to do. Changes in other packages it
    /// depends on aren't seen; SwishKit's are safe, its ABI is resilient.
    private func isUpToDate(_ library: String, package: String) -> Bool {
        let files = FileManager.default
        guard let built = (try? files.attributesOfItem(atPath: library))?[.modificationDate] as? Date else { return false }
        var inputs = [package + "/Package.swift", package + "/Package.resolved"]
        if let sources = files.enumerator(atPath: package + "/Sources") {
            for case let path as String in sources { inputs.append(package + "/Sources/" + path) }
        }
        return inputs.allSatisfy { path in
            guard let modified = (try? files.attributesOfItem(atPath: path))?[.modificationDate] as? Date else { return true }
            return modified <= built
        }
    }

    private func runSwift(_ arguments: [String]) throws -> (status: Int32, output: String) {
        guard let swift = findExecutable("swift") else {
            throw RuntimeError("import needs Swift to build packages, and swift isn't on PATH")
        }
        return try run(swift, arguments)
    }

    /// Runs a tool to completion, with its output and errors together.
    private func run(_ executable: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    // MARK: Loading

    /// Opens the library and asks each `swish_export_…` symbol for its
    /// function.
    private func load(_ name: String, from library: String) throws -> [ExportedFunction] {
        guard let handle = dlopen(library, RTLD_NOW | RTLD_LOCAL) else {
            throw RuntimeError("import \(name): \(String(cString: dlerror()))")
        }
        let symbols = try exportedSymbols(ofLibrary: library).filter { $0.hasPrefix(swishExportSymbolPrefix) }
        typealias Entry = @convention(c) () -> UnsafeMutableRawPointer
        var functions: [ExportedFunction] = []
        for symbol in symbols.sorted() {
            guard let address = dlsym(handle, symbol) else { continue }
            let entry = unsafeBitCast(address, to: Entry.self)
            let native = Unmanaged<AnyObject>.fromOpaque(entry()).takeRetainedValue()
            // A plugin that loaded its own copy of SwishKit has types the
            // shell can't recognize.
            guard let exported = native as? NativeFunction else {
                throw RuntimeError("import \(name): the plugin loaded a second copy of SwishKit; it must link the shell's")
            }
            guard exported.function.abiVersion == swishPluginABIVersion else {
                throw RuntimeError("import \(name): built for plugin ABI \(exported.function.abiVersion), but this shell has \(swishPluginABIVersion); update its SwishKit dependency and rebuild")
            }
            functions.append(exported.function)
        }
        if functions.isEmpty {
            throw RuntimeError("import \(name): the package exports nothing; mark functions with @SwishExport")
        }
        return functions
    }

    // MARK: Registering

    /// Binds each function and the enums they use. A name that's already a
    /// function gets another overload, unless the signature is the same;
    /// nothing is bound if anything clashes. `Name` holds them all too.
    private func register(_ name: String, _ exported: [ExportedFunction]) throws {
        let global = scopes[1]
        var sets: [String: [Function]] = [:]
        for export in exported {
            let function = hostFunction(export, plugin: name)
            var candidates = sets[export.name] ?? existingCandidates(export.name, importing: name)
            if let clash = candidates.first(where: { $0.hasSameSignature(as: function) }) {
                throw RuntimeError("import \(name): \(clash.signature) is already defined")
            }
            candidates.append(function)
            sets[export.name] = candidates
        }
        var enums: [String: EnumType] = [:]
        for parameter in exported.flatMap(\.parameters) {
            for type in parameter.enums {
                if let bound = lookup(type.name)?.value {
                    guard case .object(let existing as EnumType) = bound, existing === type else {
                        throw RuntimeError("import \(name): its enum \(type.name) clashes with an existing \(type.name)")
                    }
                }
                enums[type.name] = type
            }
        }
        if lookup(name) != nil {
            throw RuntimeError("import \(name): '\(name)' is already defined")
        }

        var members: [String: Value] = [:]
        for (functionName, candidates) in sets {
            let set = OverloadSet(name: functionName, candidates: candidates)
            global.bindings[functionName] = Binding(value: .function(set), mutable: false, isFunction: true)
            members[functionName] = .function(OverloadSet(name: functionName, candidates: candidates.filter { $0.plugin == name }))
        }
        for (enumName, type) in enums {
            global.bindings[enumName] = Binding(value: .object(type), mutable: false)
            members[enumName] = .object(type)
        }
        global.bindings[name] = Binding(value: .object(Module(name: name, members: members)), mutable: false)
    }

    /// The overloads `name` already has, which an import adds to; a
    /// variable of that name can't be.
    private func existingCandidates(_ name: String, importing module: String) -> [Function] {
        guard let binding = lookup(name) else { return [] }
        if binding.isFunction, case .function(let set as OverloadSet) = binding.value {
            return set.candidates
        }
        return []
    }

    /// A plugin's function as the shell's own: the same binding, help and
    /// streaming as a Swish `func`. `plugin` names the module it came from.
    func hostFunction(_ export: ExportedFunction, plugin: String? = nil) -> Function {
        let parameters = export.parameters.map { parameter in
            Parameter(
                label: parameter.label, name: parameter.name, type: TypeAnnotation(parameter.type),
                variadic: parameter.variadic, defaultValue: parameter.defaultValue.map(Expr.literal),
                isInput: parameter.isInput, shortFlag: parameter.shortFlag, externalDefault: parameter.defaultSource
            )
        }
        var docs: [String: String] = [:]
        for parameter in export.parameters {
            if let doc = parameter.documentation { docs[parameter.name] = doc }
        }
        let name = export.name
        let call = export.call
        return Function(
            name: name, parameters: parameters, returnType: export.returnType.map(TypeAnnotation.init),
            body: .native { _, arguments in
                do {
                    return try call(arguments)
                } catch let error as RuntimeError {
                    throw error
                } catch {
                    throw RuntimeError("\(name): \(error)")
                }
            },
            documentation: Documentation(summary: export.summary ?? "", parameters: docs),
            plugin: plugin, isThrowing: export.isThrowing
        )
    }
}

/// An imported module, `Tools`, whose members are what it exports:
/// `Tools.greet("Rak")`.
final class Module: SwishObject, @unchecked Sendable {
    let name: String
    let members: [String: Value]

    init(name: String, members: [String: Value]) {
        self.name = name
        self.members = members
    }

    var typeName: String { "module" }
    var memberNames: [String] { members.keys.sorted() }
    func member(_ name: String) -> Value? { members[name] }
    var fields: Record? { nil }
    var description: String { "module \(name)" }
}

extension TypeAnnotation {
    init(_ type: SwishType) {
        self = switch type {
        case .any: .any
        case .bool: .bool
        case .int: .int
        case .double: .double
        case .string: .string
        case .record: .record
        case .filesize: .filesize
        case .date: .date
        case .output: .output
        case .function: .function
        case .named(let name): .named(name)
        case .list(let element): .list(TypeAnnotation(element))
        case .optional(let wrapped): .optional(TypeAnnotation(wrapped))
        @unknown default: .any
        }
    }
}
