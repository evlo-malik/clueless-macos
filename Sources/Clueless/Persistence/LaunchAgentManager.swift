import Foundation

/// Optional per-user launch agent. Launch at login only — a quit stays quit.
enum LaunchAgentManager {
    static let label = "com.clueless.app.login"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/LaunchAgents/\(label).plist")
    }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path())
    }

    static func install() throws {
        guard let executable = Bundle.main.executablePath else {
            throw CocoaError(.fileNoSuchFile)
        }

        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable],
            "RunAtLoad": true,
            "ProcessType": "Interactive",
            "LimitLoadToSessionType": "Aqua"
        ]

        let directory = plistURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: plistURL, options: .atomic)

        let uid = getuid()
        _ = try? run("/bin/launchctl", ["bootout", "gui/\(uid)/\(label)"])
        try run("/bin/launchctl", ["bootstrap", "gui/\(uid)", plistURL.path()])
    }

    static func uninstall() throws {
        let uid = getuid()
        _ = try? run("/bin/launchctl", ["bootout", "gui/\(uid)/\(label)"])
        if isInstalled {
            try FileManager.default.removeItem(at: plistURL)
        }
    }

    @discardableResult
    private static func run(_ path: String, _ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "LaunchAgentManager",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "launchctl \(arguments.joined(separator: " ")) exited \(process.terminationStatus)"]
            )
        }
        return process.terminationStatus
    }
}
