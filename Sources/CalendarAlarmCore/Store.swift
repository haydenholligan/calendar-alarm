import Foundation

/// Config and state files under Application Support. Writes are atomic; state
/// read-modify-write is serialized across processes with a file lock.
public struct Store: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public static let standard = Store(
        directory: FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/com.corseapps.calendaralarm", directoryHint: .isDirectory)
    )

    public var configURL: URL { directory.appending(path: "config.json") }
    public var stateURL: URL { directory.appending(path: "state.json") }

    public func loadConfig() -> Config {
        load(Config.self, from: configURL) ?? Config()
    }

    public func saveConfig(_ config: Config) throws {
        try save(config, to: configURL)
    }

    public func loadState() -> State {
        load(State.self, from: stateURL) ?? State()
    }

    /// Load, mutate and save the state while holding the state lock.
    @discardableResult
    public func updateState<T>(_ body: (inout State) throws -> T) throws -> T {
        try ensureDirectory()
        let fd = try lock("state.lock", blocking: true)!
        defer { close(fd) }
        var state = loadState()
        let result = try body(&state)
        try save(state, to: stateURL)
        return result
    }

    /// Take the single-runner lock for a sync process. Returns nil if another
    /// sync already owns the schedule. The lock is released when the process exits.
    public func acquireRunLock() throws -> Int32? {
        try ensureDirectory()
        return try lock("run.lock", blocking: false)
    }

    // MARK: Private

    func ensureDirectory() throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
    }

    func lock(_ name: String, blocking: Bool) throws -> Int32? {
        let path = directory.appending(path: name).path
        let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        if flock(fd, LOCK_EX | (blocking ? 0 : LOCK_NB)) != 0 {
            let error = errno
            close(fd)
            if error == EWOULDBLOCK { return nil }
            throw POSIXError(.init(rawValue: error) ?? .EIO)
        }
        return fd
    }

    func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }

    func save<T: Encodable>(_ value: T, to url: URL) throws {
        try ensureDirectory()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
