// What SwishLibrary offers: the types and functions scripts get, and the display model their types
// use. See PublicSurface.swift for how it is checked.

enum LibrarySurface {
    /// The top-level types and protocols.
    static let types: Set<String> = [
        "DisplayColumn", "DisplayShape", "DisplayStyled", "FileEntry", "FileSize", "FileType",
        "ItemErrors", "LibraryBridge", "LibraryError", "Output", "Presentable", "ProcessEntry",
        "RecordRepresentable", "Segment", "Status", "Tabular",
    ]

    /// The public members, by the type that has them; `Date.func` is the operators the library adds to
    /// Foundation's `Date`.
    static let members: Set<String> = [
        "AttributedString.cell", "AttributedString.styledSegments", "Date.cell", "Date.func",
        "Date.init", "Date.shown", "DisplayColumn.Styling", "DisplayColumn.init",
        "DisplayColumn.name", "DisplayColumn.styling", "DisplayShape.init", "DisplayShape.isEmpty",
        "DisplayShape.isNumeric", "DisplayShape.role", "FileEntry.accessed", "FileEntry.columns",
        "FileEntry.created", "FileEntry.modified", "FileEntry.name", "FileEntry.owner",
        "FileEntry.path", "FileEntry.permissions", "FileEntry.size", "FileEntry.target",
        "FileEntry.type", "FilePath.cell", "FilePath.shape", "FileSize.bytes",
        "FileSize.description", "FileSize.encode", "FileSize.func", "FileSize.init",
        "FileSize.scriptType", "FileSize.shape", "FileSize.units", "FileType.displayStyle",
        "FileType.func", "LibraryBridge.functions", "LibraryBridge.types",
        "LibraryError.description", "LibraryError.init", "Output.Element", "Output.Index",
        "Output.cell", "Output.count", "Output.debugDescription", "Output.description",
        "Output.endIndex", "Output.first", "Output.func", "Output.init", "Output.isEmpty",
        "Output.last", "Output.lines", "Output.shape", "Output.startIndex", "Output.status",
        "Output.subscript", "Output.text", "Presentable.cell", "Presentable.shape",
        "Presentable.styledSegments", "ProcessEntry.columns", "ProcessEntry.cpuTime",
        "ProcessEntry.memory", "ProcessEntry.name", "ProcessEntry.pid", "ProcessEntry.ppid",
        "ProcessEntry.threads", "ProcessEntry.user", "RecordRepresentable.member",
        "RecordRepresentable.memberNames", "Segment.init", "Segment.style", "Segment.text",
        "Sequence.text", "Status.code", "Status.encode", "Status.init", "Status.number",
        "Status.scriptType", "Status.signal", "Status.succeeded", "Status.success", "Status.value",
    ]
}
