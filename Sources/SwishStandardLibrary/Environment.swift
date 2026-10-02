import Foundation
import SystemPackage

/// The working directory.
public func pwd() -> FilePath {
    FilePath(FileManager.default.currentDirectoryPath)
}
