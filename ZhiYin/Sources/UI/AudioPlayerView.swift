import SwiftUI
import AVFoundation

// MARK: - Duration Formatting

extension TimeInterval {
    /// Format for list items: "4.6s", "35.8s", "3m 55s"
    func formatTiming() -> String {
        if self < 1 { return String(format: "%.0fms", self * 1000) }
        if self < 60 { return String(format: "%.1fs", self) }
        let minutes = Int(self) / 60
        let seconds = self.truncatingRemainder(dividingBy: 60)
        return String(format: "%dm %.0fs", minutes, seconds)
    }

    /// Format for player: "0:00", "1:23"
    func formatPlayerTime() -> String {
        let minutes = Int(self) / 60
        let seconds = Int(self) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - Waveform Generator

final class WaveformGenerator {
    private static let cache = NSCache<NSString, NSArray>()

    static func generate(from url: URL, sampleCount: Int = 200) async -> [Float] {
        let key = url.path as NSString
        if let cached = cache.object(forKey: key) as? [Float] { return cached }

        guard let file = try? AVAudioFile(forReading: url) else { return [] }
        let frameCount = UInt32(file.length)
        let stride = max(1, Int(frameCount) / sampleCount)
        let bufSize = min(UInt32(4096), frameCount)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: bufSize) else { return [] }

        var peaks = [Float](repeating: 0, count: sampleCount)
        var idx = 0
        var pos: AVAudioFramePosition = 0

        while idx < sampleCount && pos < AVAudioFramePosition(frameCount) {
            file.framePosition = pos
            do { try file.read(into: buffer) } catch { break }
            if let data = buffer.floatChannelData?[0], buffer.frameLength > 0 {
                peaks[idx] = abs(data[0])
                idx += 1
            }
            pos += AVAudioFramePosition(stride)
        }

        if let maxVal = peaks.max(), maxVal > 0 {
            peaks = peaks.map { $0 / maxVal }
        }
        cache.setObject(peaks as NSArray, forKey: key)
        return peaks
    }
}

// MARK: - Audio Player Manager

class AudioPlayerManager: ObservableObject {
    private var player: AVAudioPlayer?
    private var timer: Timer?
    @Published var isPlaying = false
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var waveformSamples: [Float] = []
    @Published var isLoadingWaveform = false

    func load(from url: URL) {
        do {
            player = try AVAudioPlayer(contentsOf: url)
            player?.prepareToPlay()
            duration = player?.duration ?? 0
            isLoadingWaveform = true
            Task {
                let samples = await WaveformGenerator.generate(from: url)
                await MainActor.run {
                    self.waveformSamples = samples
                    self.isLoadingWaveform = false
                }
            }
        } catch {
            print("Error loading audio: \(error)")
        }
    }

    func play() {
        player?.play()
        isPlaying = true
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.currentTime = self.player?.currentTime ?? 0
            if self.currentTime >= self.duration {
                self.pause()
                self.seek(to: 0)
            }
        }
    }

    func pause() {
        player?.pause()
        isPlaying = false
        timer?.invalidate()
        timer = nil
    }

    func seek(to time: TimeInterval) {
        player?.currentTime = time
        currentTime = time
    }

    func cleanup() {
        timer?.invalidate()
        timer = nil
        player?.stop()
        player = nil
    }

    deinit { cleanup() }
}

// MARK: - Waveform View

struct WaveformView: View {
    let samples: [Float]
    let currentTime: TimeInterval
    let duration: TimeInterval
    let isLoading: Bool
    var onSeek: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            if isLoading {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Loading...").font(.system(size: 10)).foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0.5) {
                    ForEach(0..<samples.count, id: \.self) { i in
                        let progress = duration > 0 ? CGFloat(i) / CGFloat(samples.count) <= CGFloat(currentTime / duration) : false
                        Capsule()
                            .fill(progress
                                  ? Color.primary
                                  : Color.primary.opacity(0.25))
                            .frame(
                                width: max((geo.size.width / CGFloat(samples.count)) - 0.5, 1),
                                height: max(CGFloat(samples[i]) * 24, 2)
                            )
                    }
                }
                .frame(maxHeight: .infinity)
                .padding(.horizontal, 2)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let pct = max(0, min(1, Double(value.location.x / geo.size.width)))
                            onSeek(pct * duration)
                        }
                )
            }
        }
        .frame(height: 32)
    }
}

// MARK: - Audio Player View

struct AudioPlayerView: View {
    let url: URL
    var onRetranscribe: ((String) -> Void)?
    @StateObject private var manager = AudioPlayerManager()
    @AppStorage("sttEngine") private var sttEngine = "funasr"
    @State private var isHovering = false
    @State private var isRetranscribing = false
    @State private var retranscribeState: RetranscribeState = .idle

    private enum RetranscribeState {
        case idle, success, error(String)
    }

    var body: some View {
        VStack(spacing: 8) {
            WaveformView(
                samples: manager.waveformSamples,
                currentTime: manager.currentTime,
                duration: manager.duration,
                isLoading: manager.isLoadingWaveform,
                onSeek: { manager.seek(to: $0) }
            )
            .padding(.horizontal, 10)

            HStack(spacing: 8) {
                Text(manager.currentTime.formatPlayerTime())
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundColor(.secondary)

                Spacer()

                Button(action: showInFinder) {
                    Circle()
                        .fill(Color.primary.opacity(0.06))
                        .frame(width: 32, height: 32)
                        .overlay(
                            Image(systemName: "folder")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.primary)
                        )
                }
                .buttonStyle(.plain)
                .help("Show in Finder")

                Button(action: {
                    manager.isPlaying ? manager.pause() : manager.play()
                }) {
                    Circle()
                        .fill(Color.primary.opacity(0.06))
                        .frame(width: 32, height: 32)
                        .overlay(
                            Image(systemName: manager.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.primary)
                        )
                }
                .buttonStyle(.plain)
                .scaleEffect(isHovering ? 1.05 : 1.0)
                .onHover { h in
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { isHovering = h }
                }

                if onRetranscribe != nil {
                    Picker("", selection: $sttEngine) {
                        Text("FunASR").tag("funasr")
                        Text("Whisper Q4").tag("whisper")
                    }
                    .labelsHidden()
                    .frame(width: 110)
                    .controlSize(.small)
                    .onChange(of: sttEngine) {
                        LanguageSettings.shared.notifyServer()
                    }

                    Button(action: retranscribe) {
                        Circle()
                            .fill(Color.primary.opacity(0.06))
                            .frame(width: 32, height: 32)
                            .overlay(
                                Group {
                                    if isRetranscribing {
                                        ProgressView().controlSize(.small)
                                    } else if case .success = retranscribeState {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundStyle(.green)
                                    } else {
                                        Image(systemName: "arrow.clockwise")
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundStyle(.primary)
                                    }
                                }
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(isRetranscribing)
                    .help("Retranscribe with selected engine")
                }

                Spacer()

                Text(manager.duration.formatPlayerTime())
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 10)
        }
        .padding(.top, 8)
        .padding(.bottom, 6)
        .onAppear { manager.load(from: url) }
        .onDisappear { manager.cleanup() }
    }

    private func showInFinder() {
        NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
    }

    private func retranscribe() {
        isRetranscribing = true
        retranscribeState = .idle

        Task {
            do {
                let text = try await Self.transcribeFile(url: url)
                await MainActor.run {
                    isRetranscribing = false
                    retranscribeState = .success
                    onRetranscribe?(text)
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await MainActor.run { retranscribeState = .idle }
            } catch {
                await MainActor.run {
                    isRetranscribing = false
                    retranscribeState = .error(error.localizedDescription)
                }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                await MainActor.run { retranscribeState = .idle }
            }
        }
    }

    /// Upload audio file to the local STT server for transcription.
    private static func transcribeFile(url: URL) async throws -> String {
        let serverURL = URL(string: "\(ServerConfig.baseURL)/transcribe")!
        let boundary = UUID().uuidString
        var request = URLRequest(url: serverURL)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60

        let audioData = try Data(contentsOf: url)
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw NSError(domain: "Retranscribe", code: 1, userInfo: [NSLocalizedDescriptionKey: "Server error"])
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["text"] as? String else {
            throw NSError(domain: "Retranscribe", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
        }
        return text
    }
}
