import Foundation

/// Bounds memory by both entry count and bytes. Oversized snapshots remain undoable once.
public struct SnapshotHistory {
    public private(set) var undoEntries: [Data] = []
    public private(set) var redoEntries: [Data] = []
    public let maximumEntries: Int
    public let maximumBytes: Int
    public var canUndo: Bool { !undoEntries.isEmpty }
    public var canRedo: Bool { !redoEntries.isEmpty }

    public init(maximumEntries: Int = 12, maximumBytes: Int = 64 * 1_024 * 1_024) {
        self.maximumEntries = max(1, maximumEntries)
        self.maximumBytes = max(1, maximumBytes)
    }

    public mutating func record(_ before: Data) {
        undoEntries.append(before)
        redoEntries.removeAll()
        Self.trim(&undoEntries, maximumEntries: maximumEntries, maximumBytes: maximumBytes)
    }

    public mutating func undo(current: Data) -> Data? {
        guard let previous = undoEntries.popLast() else { return nil }
        redoEntries.append(current)
        Self.trim(&redoEntries, maximumEntries: maximumEntries, maximumBytes: maximumBytes)
        return previous
    }

    public mutating func redo(current: Data) -> Data? {
        guard let next = redoEntries.popLast() else { return nil }
        undoEntries.append(current)
        Self.trim(&undoEntries, maximumEntries: maximumEntries, maximumBytes: maximumBytes)
        return next
    }

    public mutating func clear() { undoEntries.removeAll(); redoEntries.removeAll() }

    private static func trim(_ entries: inout [Data], maximumEntries: Int, maximumBytes: Int) {
        var bytes = entries.reduce(0) { $0 + $1.count }
        while entries.count > 1 && (entries.count > maximumEntries || bytes > maximumBytes) {
            bytes -= entries.removeFirst().count
        }
    }
}
