import Foundation

struct ShellError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Small wrapper around Process. Streams output lines to a callback.
enum Shell {
    @discardableResult
    static func run(
        _ executable: URL,
        _ arguments: [String] = [],
        environment: [String: String]? = nil,
        directory: URL? = nil,
        onOutput: (@Sendable (String) -> Void)? = nil
    ) async throws -> Int32 {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            if let environment { process.environment = environment }
            if let directory { process.currentDirectoryURL = directory }

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                    onOutput?(String(line))
                }
            }
            process.terminationHandler = { p in
                pipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(returning: p.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                pipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }

    /// Runs and throws if the exit code is not 0.
    static func check(
        _ executable: URL,
        _ arguments: [String] = [],
        environment: [String: String]? = nil,
        directory: URL? = nil,
        onOutput: (@Sendable (String) -> Void)? = nil
    ) async throws {
        let code = try await run(executable, arguments, environment: environment, directory: directory, onOutput: onOutput)
        if code != 0 {
            throw ShellError(message: "\(executable.lastPathComponent) exited with code \(code)")
        }
    }

    /// Starts a process without waiting. Output is appended to a log file.
    static func launchDetached(
        _ executable: URL,
        _ arguments: [String],
        environment: [String: String],
        directory: URL?,
        logFile: URL,
        onExit: (@Sendable (Int32) -> Void)? = nil
    ) throws -> Process {
        FileManager.default.createFile(atPath: logFile.path, contents: nil)
        let handle = try FileHandle(forWritingTo: logFile)
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        if let directory { process.currentDirectoryURL = directory }
        process.standardOutput = handle
        process.standardError = handle
        process.terminationHandler = { p in
            try? handle.close()
            onExit?(p.terminationStatus)
        }
        try process.run()
        return process
    }

    static let tar = URL(fileURLWithPath: "/usr/bin/tar")
    static let ditto = URL(fileURLWithPath: "/usr/bin/ditto")
    static let xattr = URL(fileURLWithPath: "/usr/bin/xattr")
    static let arch = URL(fileURLWithPath: "/usr/bin/arch")
    static let env = URL(fileURLWithPath: "/usr/bin/env")

    /// Splits a command line into arguments, honouring simple quotes.
    static func splitArguments(_ line: String) -> [String] {
        var args: [String] = []
        var current = ""
        var quote: Character?
        for ch in line {
            if let q = quote {
                if ch == q { quote = nil } else { current.append(ch) }
            } else if ch == "\"" || ch == "'" {
                quote = ch
            } else if ch == " " {
                if !current.isEmpty { args.append(current); current = "" }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { args.append(current) }
        return args
    }

    static func parseEnv(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            out[String(line[..<eq])] = String(line[line.index(after: eq)...])
        }
        return out
    }
}
