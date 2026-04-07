import Foundation

// MARK: - Configuration

let portFilePath = NSString(string: "~/.zhiyin/server.port").expandingTildeInPath
let defaultPort = 17760

func serverPort() -> Int {
    guard let content = try? String(contentsOfFile: portFilePath, encoding: .utf8),
          let port = Int(content.trimmingCharacters(in: .whitespacesAndNewlines)) else {
        return defaultPort
    }
    return port
}

var serverBaseURL: String { "http://127.0.0.1:\(serverPort())" }

// MARK: - HTTP Helpers

func httpGet(_ urlString: String) -> (Data, Int)? {
    guard let url = URL(string: urlString) else { return nil }
    let semaphore = DispatchSemaphore(value: 0)
    var resultData: Data?
    var statusCode = 0

    let task = URLSession.shared.dataTask(with: url) { data, response, _ in
        resultData = data
        statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        semaphore.signal()
    }
    task.resume()
    _ = semaphore.wait(timeout: .now() + 3)
    guard let data = resultData else { return nil }
    return (data, statusCode)
}

func httpPostFile(_ urlString: String, filePath: String) -> (Data, Int)? {
    guard let url = URL(string: urlString) else { return nil }
    let fileURL = URL(fileURLWithPath: filePath)
    guard let fileData = try? Data(contentsOf: fileURL) else {
        fputs("Error: Cannot read file: \(filePath)\n", stderr)
        return nil
    }

    let boundary = UUID().uuidString
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    request.timeoutInterval = 600  // 10 min — long audio files need time

    var body = Data()
    body.append("--\(boundary)\r\n".data(using: .utf8)!)
    body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileURL.lastPathComponent)\"\r\n".data(using: .utf8)!)
    body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
    body.append(fileData)
    body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
    request.httpBody = body

    let semaphore = DispatchSemaphore(value: 0)
    var resultData: Data?
    var statusCode = 0

    let task = URLSession.shared.dataTask(with: request) { data, response, _ in
        resultData = data
        statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        semaphore.signal()
    }
    task.resume()
    _ = semaphore.wait(timeout: .now() + 600)
    guard let data = resultData else { return nil }
    return (data, statusCode)
}

func httpPost(_ urlString: String) -> (Data, Int)? {
    guard let url = URL(string: urlString) else { return nil }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = 3

    let semaphore = DispatchSemaphore(value: 0)
    var resultData: Data?
    var statusCode = 0

    let task = URLSession.shared.dataTask(with: request) { data, response, _ in
        resultData = data
        statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        semaphore.signal()
    }
    task.resume()
    _ = semaphore.wait(timeout: .now() + 5)
    guard let data = resultData else { return nil }
    return (data, statusCode)
}

func parseJSON(_ data: Data) -> [String: Any]? {
    try? JSONSerialization.jsonObject(with: data) as? [String: Any]
}

// MARK: - Commands

func checkServer() -> Bool {
    guard let (data, code) = httpGet("\(serverBaseURL)/health"),
          code == 200, let json = parseJSON(data),
          json["status"] as? String == "ok" else {
        return false
    }
    return true
}

func cmdStatus() {
    guard let (data, _) = httpGet("\(serverBaseURL)/health"),
          let json = parseJSON(data) else {
        fputs("ZhiYin server: not running\n", stderr)
        fputs("Start ZhiYin app first.\n", stderr)
        exit(1)
    }
    let engine = json["engine"] as? String ?? "unknown"
    let asr = json["asr_loaded"] as? Bool ?? false
    let vad = json["vad_loaded"] as? Bool ?? false
    print("ZhiYin server: running (port \(serverPort()), engine: \(engine), asr: \(asr), vad: \(vad))")
}

func cmdTranscribe(filePath: String, jsonOutput: Bool) {
    // Check server
    if !checkServer() {
        fputs("Error: ZhiYin app is not running. Please start it first.\n", stderr)
        exit(1)
    }

    // Check file exists
    guard FileManager.default.fileExists(atPath: filePath) else {
        fputs("Error: File not found: \(filePath)\n", stderr)
        exit(1)
    }

    // Check usage limit
    if let (usageData, _) = httpGet("\(serverBaseURL)/usage"),
       let usageJSON = parseJSON(usageData) {
        let isPro = usageJSON["is_pro"] as? Bool ?? false
        let remaining = usageJSON["remaining"] as? Int ?? 50
        if !isPro && remaining <= 0 {
            fputs("Error: Daily free limit reached (50/day). Upgrade to Pro for unlimited use.\n", stderr)
            exit(1)
        }
    }

    // Transcribe
    guard let (data, code) = httpPostFile("\(serverBaseURL)/transcribe", filePath: filePath),
          code == 200, let json = parseJSON(data) else {
        fputs("Error: Transcription failed\n", stderr)
        exit(1)
    }

    let text = json["text"] as? String ?? ""
    if text.isEmpty {
        fputs("Error: No speech recognized\n", stderr)
        exit(1)
    }

    // Record usage
    _ = httpPost("\(serverBaseURL)/usage/record")

    // Output
    if jsonOutput {
        let time = json["time"] as? Double ?? 0
        let output: [String: Any] = ["text": text, "time": time]
        if let jsonData = try? JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]),
           let jsonStr = String(data: jsonData, encoding: .utf8) {
            print(jsonStr)
        }
    } else {
        print(text)
    }
}

func cmdHelp() {
    print("""
    zhiyin-stt — Speech-to-text from the command line

    Usage:
      zhiyin-stt <audio_file>          Transcribe audio to text
      zhiyin-stt <audio_file> --json   Output as JSON
      zhiyin-stt --status              Check server status
      zhiyin-stt --help                Show this help

    Requires ZhiYin app to be running.
    Uses the app's current model and language settings.
    """)
}

// MARK: - Main

let args = CommandLine.arguments.dropFirst()

if args.isEmpty || args.contains("--help") || args.contains("-h") {
    cmdHelp()
    exit(0)
}

if args.contains("--status") {
    cmdStatus()
    exit(0)
}

// Find file argument (first arg that's not a flag)
guard let filePath = args.first(where: { !$0.hasPrefix("-") }) else {
    cmdHelp()
    exit(1)
}

let jsonOutput = args.contains("--json")
cmdTranscribe(filePath: filePath, jsonOutput: jsonOutput)
