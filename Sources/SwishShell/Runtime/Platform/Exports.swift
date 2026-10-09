@_spi(Shell) import Swiit
import Foundation

/// A dynamic library's file name on this platform: `libTools.dylib`, `libTools.so`.
func dynamicLibraryName(_ name: String) -> String {
    #if canImport(Darwin)
    "lib\(name).dylib"
    #else
    "lib\(name).so"
    #endif
}

/// The C names of the symbols a dynamic library defines and exports, read
/// from the file itself: a Mach-O's symbol table, or an ELF's dynamic
/// symbols. What `nm -gU` lists, without needing nm.
func exportedSymbols(ofLibrary path: String) throws -> [String] {
    let data = try Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped)
    return try data.withUnsafeBytes { bytes throws -> [String] in
        let file = BinaryReader(bytes: bytes)
        if try file.u32(0) == 0xFEED_FACF { return try machOExports(file) }
        if try file.u32(0) == 0x464C_457F { return try elfExports(file) } // "\u{7F}ELF"
        throw RuntimeError("\(path) isn't a 64-bit Mach-O or ELF library")
    }
}

/// Little-endian fields at offsets in a file, checked against its end.
private struct BinaryReader {
    let bytes: UnsafeRawBufferPointer

    func load<T: FixedWidthInteger>(_ offset: Int, as type: T.Type) throws -> T {
        guard offset >= 0, offset + MemoryLayout<T>.size <= bytes.count else { throw RuntimeError("the library is cut short") }
        return T(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: T.self))
    }

    func u8(_ offset: Int) throws -> UInt8 { try load(offset, as: UInt8.self) }
    func u16(_ offset: Int) throws -> Int { Int(try load(offset, as: UInt16.self)) }
    func u32(_ offset: Int) throws -> UInt32 { try load(offset, as: UInt32.self) }
    func u64(_ offset: Int) throws -> Int { Int(try load(offset, as: UInt64.self)) }

    /// The NUL-terminated string at `offset`.
    func string(_ offset: Int) throws -> String {
        guard offset >= 0, offset < bytes.count else { throw RuntimeError("the library is cut short") }
        var end = offset
        while end < bytes.count, bytes[end] != 0 { end += 1 }
        return String(decoding: bytes[offset..<end], as: UTF8.self)
    }
}

/// Mach-O: the LC_SYMTAB command's table, keeping external symbols defined
/// in a section, without the leading underscore C names carry.
private func machOExports(_ file: BinaryReader) throws -> [String] {
    let commandCount = Int(try file.u32(16))
    var command = 32 // After mach_header_64.
    for _ in 0..<commandCount {
        let kind = try file.u32(command), size = Int(try file.u32(command + 4))
        if kind == 0x2 { // LC_SYMTAB
            let symbols = Int(try file.u32(command + 8)), count = Int(try file.u32(command + 12))
            let strings = Int(try file.u32(command + 16))
            var names: [String] = []
            for index in 0..<count {
                let entry = symbols + index * 16 // nlist_64
                let type = try file.u8(entry + 4)
                // N_EXT, and N_TYPE is N_SECT: defined here and visible.
                guard type & 0x01 != 0, type & 0x0E == 0x0E else { continue }
                let name = try file.string(strings + Int(try file.u32(entry)))
                names.append(name.hasPrefix("_") ? String(name.dropFirst()) : name)
            }
            return names
        }
        command += size
    }
    return []
}

/// ELF: the .dynsym section, keeping global and weak symbols that are
/// defined (their section isn't SHN_UNDEF).
private func elfExports(_ file: BinaryReader) throws -> [String] {
    guard try file.u8(4) == 2, try file.u8(5) == 1 else { throw RuntimeError("the library isn't a 64-bit little-endian ELF") }
    let sections = try file.u64(0x28), sectionSize = try file.u16(0x3A), sectionCount = try file.u16(0x3C)
    func section(_ index: Int) -> Int { sections + index * sectionSize }
    for index in 0..<sectionCount where try file.u32(section(index) + 4) == 11 { // SHT_DYNSYM
        let table = try file.u64(section(index) + 0x18), size = try file.u64(section(index) + 0x20)
        let entrySize = max(try file.u64(section(index) + 0x38), 24)
        let strings = try file.u64(section(Int(try file.u32(section(index) + 0x28))) + 0x18)
        var names: [String] = []
        for entry in stride(from: table, to: table + size, by: entrySize) {
            let binding = try file.u8(entry + 4) >> 4
            guard binding == 1 || binding == 2, try file.u16(entry + 6) != 0 else { continue }
            names.append(try file.string(strings + Int(try file.u32(entry))))
        }
        return names
    }
    return []
}
