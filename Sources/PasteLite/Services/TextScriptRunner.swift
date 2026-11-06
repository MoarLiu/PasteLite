import Foundation
import Darwin

actor TextScriptRunner {
    /// Scripts run only after a user chooses a file and clicks Run. The chosen
    /// shell script receives UTF-8 stdin and returns UTF-8 stdout; it has the
    /// user's normal file/network permissions.
    func run(script: URL, input: String) async throws -> String {
        guard script.isFileURL, script.pathExtension == "sh",
              input.utf8.count <= LibraryValidation.snippetByteLimit else { throw LibraryError.invalid("Choose a local .sh script and text up to 1 MiB.") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PasteLiteScript-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let inURL = directory.appendingPathComponent("input"), outURL = directory.appendingPathComponent("output"), errURL = directory.appendingPathComponent("error")
        try Data(input.utf8).write(to: inURL)
        _ = FileManager.default.createFile(atPath: outURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        _ = FileManager.default.createFile(atPath: errURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let stdin = try FileHandle(forReadingFrom: inURL), stdout = try FileHandle(forWritingTo: outURL), stderr = try FileHandle(forWritingTo: errURL)
        defer { try? stdin.close(); try? stdout.close(); try? stderr.close() }
        let process = try ScriptProcess(script: script, input: stdin, output: stdout, error: stderr)
        // Kill the owned process group on every exit, including a shell that
        // exits successfully after leaving background children running.
        defer { process.stop() }
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        do {
            while try process.isRunning() {
                try Task.checkCancellation()
                let outSize = try outURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                let errSize = try errURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard outSize <= LibraryValidation.snippetByteLimit, errSize <= 65536 else { throw LibraryError.invalid("Script output exceeded the size limit.") }
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw LibraryError.invalid("Script exceeded the five-second limit.") }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            try Task.checkCancellation()
            guard process.terminationStatus == 0 else {
                let message = String(data: try Data(contentsOf: errURL), encoding: .utf8) ?? ""
                throw LibraryError.invalid(message.isEmpty ? "The script failed." : String(message.prefix(1000)))
            }
            let data = try Data(contentsOf: outURL)
            guard data.count <= LibraryValidation.snippetByteLimit, let text = String(data: data, encoding: .utf8) else { throw LibraryError.invalid("The script must return UTF-8 text up to 1 MiB.") }
            return text
        } catch {
            throw error
        }
    }
}

private final class ScriptProcess {
    private let pid: pid_t
    private var reaped = false
    private(set) var terminationStatus: Int32 = -1

    init(script: URL, input: FileHandle, output: FileHandle, error: FileHandle) throws {
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        posix_spawn_file_actions_adddup2(&actions, input.fileDescriptor, STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, output.fileDescriptor, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, error.fileDescriptor, STDERR_FILENO)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)
        let command = "ulimit -f 2048; ulimit -t 5; cd -- \"$2\" || exit; exec /bin/sh \"$1\""
        let arguments = ["/bin/sh", "-c", command, "pastelite-script", script.path, script.deletingLastPathComponent().path]
        let environment = ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" }
        let argv = arguments.map { strdup($0) } + [nil]
        let envp = environment.map { strdup($0) } + [nil]
        defer { for value in argv + envp { free(value) } }
        var child: pid_t = 0
        let status = argv.withUnsafeBufferPointer { argv in
            envp.withUnsafeBufferPointer { envp in
                posix_spawn(&child, "/bin/sh", &actions, &attributes, argv.baseAddress!, envp.baseAddress!)
            }
        }
        guard status == 0 else { throw POSIXError(POSIXErrorCode(rawValue: status) ?? .EIO) }
        pid = child
    }

    func isRunning() throws -> Bool {
        guard !reaped else { return false }
        var status: Int32 = 0
        let result = waitpid(pid, &status, WNOHANG)
        if result == 0 { return true }
        if result < 0 {
            if errno == EINTR { return true }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ECHILD)
        }
        reaped = true
        terminationStatus = status == 0 ? 0 : 1
        return false
    }

    func stop() {
        kill(-pid, SIGKILL)
        if !reaped {
            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0 && errno == EINTR { }
            reaped = true
        }
    }
}
