import Foundation

// MARK: What a plugin exports

/// Raised when a plugin built against an older SwishKit can no longer be
/// loaded. Library evolution lets SwishKit add to these types without it.
/// 2: a file size is a boxed Swift value, no longer a case of `Value`.
///
/// Transparent, so it's compiled into each plugin as its number when the
/// plugin was built, not read from SwishKit when it's loaded, which would
/// always agree.
@_transparent public var swishPluginABIVersion: Int { 2 }

/// Each `@SwishExport` function also defines a C symbol with this prefix
/// and its name, `swish_export_greet`, returning a retained
/// `NativeFunction`. The shell finds a plugin's exports by these, so
/// there's nothing to list.
public let swishExportSymbolPrefix = "swish_export_"

/// A Swift function as Swish sees it: the same signature a `func` in Swish
/// has, so it gets a command line, `--help` and completion the same way.
/// `@SwishExport` builds one from a declaration.
public struct ExportedFunction: Sendable {
    public let name: String
    public let summary: String?
    public let parameters: [ExportedParameter]
    public let returnType: SwishType?
    /// The `swishPluginABIVersion` the plugin was built with.
    public let abiVersion: Int
    /// Declared `throws`: a call to it needs `try`.
    public let isThrowing: Bool
    /// Called with every argument bound, by parameter name, except ones
    /// left to a Swift default (`defaultSource`).
    public let call: @Sendable ([String: Value]) throws -> Value

    public init(
        name: String, summary: String? = nil, parameters: [ExportedParameter], returnType: SwishType?,
        abiVersion: Int = swishPluginABIVersion, isThrowing: Bool,
        call: @escaping @Sendable ([String: Value]) throws -> Value
    ) {
        self.abiVersion = abiVersion
        self.isThrowing = isThrowing
        self.name = name
        self.summary = summary
        self.parameters = parameters
        self.returnType = returnType
        self.call = call
    }

    /// As plugins built before `isThrowing` call it: SwishKit keeps every
    /// public initializer it has shipped, so they still load.
    public init(
        name: String, summary: String? = nil, parameters: [ExportedParameter], returnType: SwishType?,
        abiVersion: Int = swishPluginABIVersion, call: @escaping @Sendable ([String: Value]) throws -> Value
    ) {
        self.init(name: name, summary: summary, parameters: parameters, returnType: returnType,
                  abiVersion: abiVersion, isThrowing: false, call: call)
    }
}

public struct ExportedParameter: Sendable {
    /// nil for `_`: positional on the command line.
    public let label: String?
    public let name: String
    public let type: SwishType
    /// The enums its type uses, which the shell learns by name.
    public let enums: [EnumType]
    public let variadic: Bool
    /// `@Input`: receives what's piped in.
    public let isInput: Bool
    /// `@Flag("n")`.
    public let shortFlag: Character?
    public let documentation: String?
    /// A literal default, which the shell fills in and `--help` shows.
    public let defaultValue: Value?
    /// A default only Swift can compute, like `Date()`: the argument is
    /// left out and the function uses its own. Its source, for `--help`.
    public let defaultSource: String?

    public init(
        label: String?, name: String, type: SwishType, enums: [EnumType] = [], variadic: Bool = false, isInput: Bool = false,
        shortFlag: Character? = nil, documentation: String? = nil, defaultValue: Value? = nil, defaultSource: String? = nil
    ) {
        self.label = label
        self.name = name
        self.type = type
        self.enums = enums
        self.variadic = variadic
        self.isInput = isInput
        self.shortFlag = shortFlag
        self.documentation = documentation
        self.defaultValue = defaultValue
        self.defaultSource = defaultSource
    }
}

/// The type of a parameter or result, as Swish's type annotations name it.
public indirect enum SwishType: Sendable, Hashable, CustomStringConvertible {
    case any, bool, int, double, string, record, filesize, date, output, function
    /// An enum the plugin exports, like `Level`.
    case named(String)
    case list(SwishType)
    case optional(SwishType)

    public var description: String {
        switch self {
        case .any: "Any"
        case .bool: "Bool"
        case .int: "Int"
        case .double: "Double"
        case .string: "String"
        case .record: "Record"
        case .filesize: "FileSize"
        case .date: "Date"
        case .output: "Output"
        case .function: "Function"
        case .named(let name): name
        case .list(let element): "[\(element)]"
        case .optional(let wrapped): "\(wrapped)?"
        }
    }
}

/// A plugin function or method as a value, as `repo.log` gives it. The
/// shell calls it like any other function.
public final class NativeFunction: Callable, @unchecked Sendable {
    public let function: ExportedFunction

    public init(_ function: ExportedFunction) {
        self.function = function
    }

    public var description: String {
        "<func \(function.name)(\(function.parameters.map { ($0.label ?? "_") + ":" }.joined()))>"
    }
}

/// A failure in converting between Swift and Swish values, or one a plugin
/// throws to report a problem the way the shell's own errors read.
public struct SwishError: Error, CustomStringConvertible {
    public let description: String

    public init(_ description: String) {
        self.description = description
    }
}

// MARK: Converting values

/// A Swift type that can be a parameter: the shell hands it a `Value`, and
/// it says what type the shell should check for.
public protocol SwishConvertible {
    static var swishType: SwishType { get }
    /// The enums `swishType` names, for the shell to register.
    static var swishEnums: [EnumType] { get }
    init(swishValue: Value) throws
    var swishValue: Value { get }
}

extension SwishConvertible {
    public static var swishEnums: [EnumType] { [] }
}

extension Value: SwishConvertible {
    public static var swishType: SwishType { .any }
    public init(swishValue: Value) { self = swishValue }
    public var swishValue: Value { self }
}

extension Int: SwishConvertible {
    public static var swishType: SwishType { .int }
    public init(swishValue: Value) throws {
        guard case .int(let value) = swishValue else { throw SwishError.expected("Int", swishValue) }
        self = value
    }
    public var swishValue: Value { .int(self) }
}

extension Double: SwishConvertible {
    public static var swishType: SwishType { .double }
    public init(swishValue: Value) throws {
        switch swishValue {
        case .double(let value): self = value
        case .int(let value): self = Double(value)
        default: throw SwishError.expected("Double", swishValue)
        }
    }
    public var swishValue: Value { .double(self) }
}

extension String: SwishConvertible {
    public static var swishType: SwishType { .string }
    public init(swishValue: Value) throws {
        switch swishValue {
        case .string(let value): self = value
        case .output(let output): self = output.text
        default: throw SwishError.expected("String", swishValue)
        }
    }
    public var swishValue: Value { .string(self) }
}

extension Bool: SwishConvertible {
    public static var swishType: SwishType { .bool }
    public init(swishValue: Value) throws {
        guard case .bool(let value) = swishValue else { throw SwishError.expected("Bool", swishValue) }
        self = value
    }
    public var swishValue: Value { .bool(self) }
}

extension Date: SwishConvertible {
    public static var swishType: SwishType { .date }
    public init(swishValue: Value) throws {
        guard case .date(let value) = swishValue else { throw SwishError.expected("Date", swishValue) }
        self = value
    }
    public var swishValue: Value { .date(self) }
}

extension FileSize: SwishConvertible {
    public static var swishType: SwishType { .filesize }
    public init(swishValue: Value) throws {
        if let size = swishValue.fileSize {
            self = size
        } else if case .int(let bytes) = swishValue {
            self.init(bytes: bytes)
        } else {
            throw SwishError.expected("FileSize", swishValue)
        }
    }
    public var swishValue: Value { .fileSize(self) }
}

extension CommandOutput: SwishConvertible {
    public static var swishType: SwishType { .output }
    public init(swishValue: Value) throws {
        guard case .output(let value) = swishValue else { throw SwishError.expected("Output", swishValue) }
        self = value
    }
    public var swishValue: Value { .output(self) }
}

extension Array: SwishConvertible where Element: SwishConvertible {
    public static var swishType: SwishType { .list(Element.swishType) }
    public static var swishEnums: [EnumType] { Element.swishEnums }
    public init(swishValue: Value) throws {
        switch swishValue {
        case .list(let items): self = try items.map(Element.init(swishValue:))
        case .output(let output): self = try output.lines.map { try Element(swishValue: .string($0)) }
        default: throw SwishError.expected("[\(Element.swishType)]", swishValue)
        }
    }
    public var swishValue: Value { .list(map(\.swishValue)) }
}

extension Optional: SwishConvertible where Wrapped: SwishConvertible {
    public static var swishType: SwishType { .optional(Wrapped.swishType) }
    public static var swishEnums: [EnumType] { Wrapped.swishEnums }
    public init(swishValue: Value) throws {
        self = swishValue == .nothing ? nil : try Wrapped(swishValue: swishValue)
    }
    public var swishValue: Value { map(\.swishValue) ?? .nothing }
}

extension SwishError {
    static func expected(_ type: String, _ value: Value) -> SwishError {
        SwishError("expected \(type), not \(value.typeName)")
    }
}

extension Value {
    /// The type name error messages use.
    var typeName: String {
        switch self {
        case .nothing: "nil"
        case .bool: "Bool"
        case .int: "Int"
        case .double: "Double"
        case .string: "String"
        case .list: "List"
        case .record(let record): record.typeName ?? "Record"
        case .dictionary: "Dictionary"
        case .date: "Date"
        case .output: "Output"
        case .enumValue(let value): value.type.name
        case .object(let object): object.typeName
        case .function: "Function"
        }
    }

    /// A function's result, whatever Swift type it has: a convertible
    /// value, an exported object, `Encodable` data as records, or nothing.
    public init(returning result: Any) throws {
        switch result {
        case is Void: self = .nothing
        case let value as any SwishConvertible: self = value.swishValue
        case let object as any SwishObject: self = .object(object)
        case let objects as [any SwishObject]: self = .list(objects.map(Value.object))
        case let data as any Encodable: self = try ValueEncoder().encode(data)
        default: throw SwishError("can't return a \(type(of: result)) to Swish; make it Encodable or @SwishExport it")
        }
    }
}

/// What the shell checks a parameter's arguments against.
public func swishParameterType<T: SwishConvertible>(_ type: T.Type) -> SwishType { T.swishType }
/// An exported object: anything, checked when it's converted.
public func swishParameterType<T: SwishObject>(_ type: T.Type) -> SwishType { .any }

public func swishParameterEnums<T: SwishConvertible>(_ type: T.Type) -> [EnumType] { T.swishEnums }
public func swishParameterEnums<T: SwishObject>(_ type: T.Type) -> [EnumType] { [] }

/// What a function returns, for signatures and `--help`.
public func swishReturnType(_ type: Any.Type) -> SwishType {
    (type as? any SwishConvertible.Type)?.swishType ?? .any
}

/// An object argument: one of the plugin's own exported classes.
public func swishArgument<T: SwishObject>(
    _ arguments: [String: Value], _ name: String, of function: String, as type: T.Type = T.self
) throws -> T {
    guard case .object(let object as T) = arguments[name] ?? .nothing else {
        throw SwishError("\(function): \(name): expected \(T.self), not \((arguments[name] ?? .nothing).typeName)")
    }
    return object
}

/// An argument the macro-generated code converts: a clear message naming
/// the function and parameter when it doesn't fit.
public func swishArgument<T: SwishConvertible>(
    _ arguments: [String: Value], _ name: String, of function: String, as type: T.Type = T.self
) throws -> T {
    do {
        return try T(swishValue: arguments[name] ?? .nothing)
    } catch let error as SwishError {
        throw SwishError("\(function): \(name): \(error)")
    }
}

/// A Swift enum Swish can use: as a parameter (`volume .high`, or
/// `volume(.high)`), a result, and in `switch`. Conforming is all it takes,
/// for an enum without associated values:
///
///     public enum Level: String, CaseIterable, SwishEnum { case low, high }
///
/// The shell learns it by name from the functions that take it.
public protocol SwishEnum: SwishConvertible, CaseIterable {
    /// Its cases and raw values, as Swish sees them; one instance per type,
    /// so values compare equal across calls.
    static var swishEnumType: EnumType { get }
}

extension SwishEnum {
    public static var swishEnumType: EnumType {
        EnumRegistry.shared.type(for: Self.self) {
            EnumType(name: String(describing: Self.self), cases: allCases.map { value in
                let raw = (value as? any RawRepresentable)?.rawValue
                return EnumType.Case(name: String(describing: value), rawValue: raw.flatMap { raw in
                    switch raw {
                    case let int as Int: .int(int)
                    case let string as String: .string(string)
                    default: nil
                    }
                })
            })
        }
    }

    public static var swishType: SwishType { .named(swishEnumType.name) }
    public static var swishEnums: [EnumType] { [swishEnumType] }

    public init(swishValue: Value) throws {
        guard case .enumValue(let value) = swishValue, value.type === Self.swishEnumType,
              let found = Self.allCases.first(where: { String(describing: $0) == value.name }) else {
            throw SwishError.expected(Self.swishEnumType.name, swishValue)
        }
        self = found
    }

    public var swishValue: Value {
        .enumValue(EnumValue(type: Self.swishEnumType, name: String(describing: self)))
    }
}

/// Each `SwishEnum`'s `EnumType`, made once.
final class EnumRegistry: @unchecked Sendable {
    static let shared = EnumRegistry()
    private let lock = NSLock()
    private var types: [ObjectIdentifier: EnumType] = [:]

    func type(for key: Any.Type, _ make: () -> EnumType) -> EnumType {
        lock.lock()
        defer { lock.unlock() }
        if let type = types[ObjectIdentifier(key)] { return type }
        let type = make()
        types[ObjectIdentifier(key)] = type
        return type
    }
}

// MARK: Macros

/// Exports a function to Swish: its signature, doc comment, `@Flag`s and
/// `@Input` become the same command line and `--help` a Swish `func` gets.
/// Importing the package is all that's needed; there's nothing to list.
@attached(peer, names: prefixed(__swish_export_))
public macro SwishExport() = #externalMacro(module: "SwishKitMacros", type: "SwishExportMacro")

/// Makes a class a live object in Swish: its public properties and methods
/// are members (`counter.total`, `counter.add(2)`), shown as fields in
/// tables. Return it from an exported function to hand it out.
@attached(extension, conformances: SwishObject, Sendable, names: named(typeName), named(memberNames), named(member), named(description))
public macro SwishObject() = #externalMacro(module: "SwishKitMacros", type: "SwishObjectMacro")

/// `@Flag("n") times: Int = 1`: a short flag on the command line. It only
/// marks the parameter for `@SwishExport`; the value passes through.
/// `@Flag all: Bool = false` alone makes the parameter's first letter the
/// flag (`-a`), which is the form a symbol graph can read: it keeps the
/// attribute's name but not its arguments.
@propertyWrapper
public struct Flag<T> {
    public var wrappedValue: T
    public init(wrappedValue: T, _ short: Character) { self.wrappedValue = wrappedValue }
    public init(wrappedValue: T) { self.wrappedValue = wrappedValue }
}

/// `@Rest _ paths: [FilePath] = []`: takes any number of arguments, as
/// `FilePath...` does in Swift, which can't pass the array on to another
/// variadic: so it's declared as the array, and marked.
@propertyWrapper
public struct Rest<T> {
    public var wrappedValue: T
    public init(wrappedValue: T) { self.wrappedValue = wrappedValue }
}

/// `@Input _ lines: [String]`: receives what's piped in, per item, or the
/// whole stream for a list. Only a marker for `@SwishExport`.
@propertyWrapper
public struct Input<T> {
    public var wrappedValue: T
    public init(wrappedValue: T) { self.wrappedValue = wrappedValue }
}

