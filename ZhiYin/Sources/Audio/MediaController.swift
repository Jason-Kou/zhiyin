import Foundation

/// Controls system media playback using MRMediaRemote private API
/// Used to pause media during recording and resume after
class MediaController {
    private var wasPlaying = false

    // MRMediaRemote function types
    private typealias MRMediaRemoteGetNowPlayingInfoFunc = @convention(c) (DispatchQueue, @escaping ([String: Any]) -> Void) -> Void
    private typealias MRMediaRemoteSendCommandFunc = @convention(c) (UInt32, UnsafeRawPointer?) -> Bool

    private static let bundle: CFBundle? = {
        CFBundleCreate(kCFAllocatorDefault, NSURL(fileURLWithPath: "/System/Library/PrivateFrameworks/MediaRemote.framework"))
    }()

    private static func getFunction<T>(_ name: String) -> T? {
        guard let bundle = bundle else { return nil }
        guard let ptr = CFBundleGetFunctionPointerForName(bundle, name as CFString) else { return nil }
        return unsafeBitCast(ptr, to: T.self)
    }

    // MRMediaRemote commands
    private static let kMRPlay: UInt32 = 0
    private static let kMRPause: UInt32 = 1
    private static let kMRTogglePlayPause: UInt32 = 2

    /// Check if media is currently playing and pause it
    func pauseIfPlaying() {
        guard let getInfo: MRMediaRemoteGetNowPlayingInfoFunc = Self.getFunction("MRMediaRemoteGetNowPlayingInfo") else {
            return
        }

        getInfo(DispatchQueue.main) { [weak self] info in
            // kMRMediaRemoteNowPlayingInfoPlaybackRate
            let rate = info["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? Double ?? 0
            if rate > 0 {
                self?.wasPlaying = true
                self?.sendCommand(Self.kMRPause)
            } else {
                self?.wasPlaying = false
            }
        }
    }

    /// Resume playback if it was playing before
    func resumeIfWasPlaying() {
        guard wasPlaying else { return }
        wasPlaying = false
        sendCommand(Self.kMRPlay)
    }

    private func sendCommand(_ command: UInt32) {
        guard let send: MRMediaRemoteSendCommandFunc = Self.getFunction("MRMediaRemoteSendCommand") else {
            return
        }
        _ = send(command, nil)
    }
}
