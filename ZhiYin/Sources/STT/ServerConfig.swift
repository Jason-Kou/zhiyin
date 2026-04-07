import Foundation

/// Central configuration for the Python STT server connection.
/// Reads the port from ~/.zhiyin/server.port (written by the Python server on startup).
/// Falls back to default port 17760 if the file doesn't exist.
enum ServerConfig {
    static let defaultPort = 17760
    private static let portFilePath = NSString(string: "~/.zhiyin/server.port").expandingTildeInPath

    static var port: Int {
        guard let content = try? String(contentsOfFile: portFilePath, encoding: .utf8),
              let port = Int(content.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return defaultPort
        }
        return port
    }

    static var baseURL: String {
        "http://127.0.0.1:\(port)"
    }
}
