import AppKit
import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

/// AUHAL-based audio recorder. Records from any input device to a 16kHz mono
/// WAV file without changing the system default device.
class AudioRecorder {
    private var audioUnit: AudioUnit?
    private var audioFile: ExtAudioFileRef?
    private var tempURL: URL?
    private var recordingStartTime: Date?

    // Device format (what the hardware provides)
    private var deviceFormat = AudioStreamBasicDescription()

    // Output format (16kHz mono Int16 for WAV file)
    private var outputFormat = AudioStreamBasicDescription()

    // Pre-allocated buffers for real-time callback
    private var renderBuffer: UnsafeMutablePointer<Float32>?
    private var renderBufferSize: UInt32 = 0
    private var conversionBuffer: UnsafeMutablePointer<Int16>?
    private var conversionBufferSize: UInt32 = 0

    /// Accumulated 16kHz mono Float32 samples for streaming transcription
    private var accumulatedSamples: [Float] = []
    private let samplesLock = NSLock()

    /// Index tracking how many samples have been sent as chunks
    private var chunkSentIndex: Int = 0

    private var isRecording = false

    /// Target sample rate for output
    private let targetSampleRate: Double = 16000

    /// Minimum recording duration in seconds
    private let minimumDuration: TimeInterval = 0.5

    // MARK: - Public Interface

    /// Play start-recording sound (short ascending tone)
    func playStartSound() {
        AudioServicesPlaySystemSound(1113)
    }

    /// Play stop-recording sound (short descending tone)
    func playStopSound() {
        AudioServicesPlaySystemSound(1114)
    }

    /// Play forced-stop alert sound (per D-05: distinct from normal stop sound 1114)
    func playForceStopSound() {
        NSSound.beep()  // System alert sound, clearly distinct from 1113/1114 tones
    }

    /// True while every sample captured so far has been exactly zero.
    ///
    /// This is the signature of a muted or dead input device, and it is worth
    /// distinguishing from "quiet": a real room always has a noise floor, so a
    /// softly-speaking user still produces non-zero samples. Testing for literal
    /// silence rather than a low RMS means the warning cannot fire on someone who
    /// simply talks quietly, or in the moment before they start speaking.
    ///
    /// Without this the failure is invisible — the recording uploads, the server
    /// returns an empty string, nothing is pasted, and nothing explains why.
    var capturedOnlySilence: Bool {
        samplesLock.lock()
        defer { samplesLock.unlock() }
        return capturedSampleCount > 0 && capturedPeak == 0
    }

    private var capturedPeak: Float = 0
    private var capturedSampleCount: Int = 0

    /// Whether the last recording was too short to be useful
    var wasRecordingTooShort: Bool {
        guard let start = recordingStartTime else { return true }
        return Date().timeIntervalSince(start) < minimumDuration
    }

    /// Returns new samples since the last call (incremental chunk upload).
    /// Thread-safe. Compacts array to prevent unbounded growth (SAFE-04).
    func drainNewSamples() -> [Float]? {
        samplesLock.lock()
        let total = accumulatedSamples.count
        let start = chunkSentIndex
        guard total > start else {
            // No new samples, but compact if old ones exist
            if start > 0 {
                accumulatedSamples.removeAll(keepingCapacity: true)
                chunkSentIndex = 0
            }
            samplesLock.unlock()
            return nil
        }
        let newSamples = Array(accumulatedSamples[start..<total])

        // Memory compaction: remove all drained samples.
        // Only remove up to `total` (not removeAll) because the audio callback
        // may have appended more samples between reading `total` and here.
        accumulatedSamples.removeSubrange(0..<total)
        chunkSentIndex = 0

        samplesLock.unlock()
        return newSamples.isEmpty ? nil : newSamples
    }

    func startRecording() {
        playStartSound()
        recordingStartTime = Date()
        samplesLock.lock()
        accumulatedSamples.removeAll()
        chunkSentIndex = 0
        capturedPeak = 0
        capturedSampleCount = 0
        samplesLock.unlock()

        // Stop any previous recording
        stopAudioUnit()

        // Initialize AUHAL off the main thread to avoid blocking UI
        // when Bluetooth devices (AirPods) are slow to respond
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            self.withMicrophoneAccess { granted in
                guard granted else {
                    print("AudioRecorder: Microphone access denied — cannot record")
                    return
                }
                do {
                    try self.setupAndStart()
                } catch {
                    print("AudioRecorder: Failed to start: \(error)")
                }
            }
        }
    }

    /// Nothing in the app ever asked for microphone access, so on a fresh install
    /// CoreAudio simply failed to open the device and recording produced nothing.
    /// AUHAL does not raise the system prompt on its own the way AVFoundation does.
    private func withMicrophoneAccess(_ body: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            body(true)
        case .notDetermined:
            // Prompts once; the callback lands on an arbitrary queue.
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                body(granted)
            }
        default:
            body(false)
        }
    }

    /// Stop recording and return the URL of the recorded WAV file
    func stopRecording() -> URL? {
        playStopSound()
        stopAudioUnit()
        return tempURL
    }

    /// Clean up temp files
    func cleanup() {
        if let url = tempURL {
            try? FileManager.default.removeItem(at: url)
            tempURL = nil
        }
    }

    deinit {
        stopAudioUnit()
    }

    // MARK: - AUHAL Setup

    private func setupAndStart() throws {
        // 1. Resolve target device
        let deviceID = resolveTargetDevice()

        // 2. Create AUHAL AudioUnit
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )

        guard let component = AudioComponentFindNext(nil, &desc) else {
            throw RecorderError.audioUnitNotFound
        }

        var unit: AudioUnit?
        guard AudioComponentInstanceNew(component, &unit) == noErr, let au = unit else {
            throw RecorderError.setupFailed("Failed to create AudioUnit")
        }

        // Enable input on element 1
        var enableInput: UInt32 = 1
        AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO,
                             kAudioUnitScope_Input, 1,
                             &enableInput, UInt32(MemoryLayout<UInt32>.size))

        // Disable output on element 0
        var disableOutput: UInt32 = 0
        AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO,
                             kAudioUnitScope_Output, 0,
                             &disableOutput, UInt32(MemoryLayout<UInt32>.size))

        // 3. Set input device (does NOT change system default)
        var devID = deviceID
        let setStatus = AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice,
                                             kAudioUnitScope_Global, 0,
                                             &devID, UInt32(MemoryLayout<AudioDeviceID>.size))
        if setStatus != noErr {
            print("AudioRecorder: Failed to set device (status: \(setStatus)), using system default")
        } else {
            print("AudioRecorder: Device set (ID: \(deviceID))")
        }

        // 4. Get device native format
        //
        // This query fails whenever the input device cannot actually be opened —
        // microphone permission not granted, device unplugged, or claimed
        // exclusively by another process. deviceFormat then keeps its zero value,
        // and step 7 divides by mSampleRate. Dividing by zero yields infinity,
        // and UInt32(infinity) is a Swift runtime trap, so an unusable microphone
        // used to crash the app instead of surfacing an error.
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let formatStatus = AudioUnitGetProperty(au, kAudioUnitProperty_StreamFormat,
                                                kAudioUnitScope_Input, 1,
                                                &deviceFormat, &formatSize)
        guard formatStatus == noErr else {
            AudioComponentInstanceDispose(au)
            throw RecorderError.setupFailed("Could not read input format (status \(formatStatus)) — check microphone permission")
        }
        guard deviceFormat.mSampleRate > 0, deviceFormat.mChannelsPerFrame > 0 else {
            AudioComponentInstanceDispose(au)
            throw RecorderError.setupFailed("Input device reported an unusable format (\(deviceFormat.mSampleRate)Hz, \(deviceFormat.mChannelsPerFrame)ch)")
        }

        print("AudioRecorder: Device format: \(deviceFormat.mSampleRate)Hz, \(deviceFormat.mChannelsPerFrame)ch")

        // 5. Set callback format (Float32 at device sample rate)
        var callbackFormat = AudioStreamBasicDescription(
            mSampleRate: deviceFormat.mSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(MemoryLayout<Float32>.size) * deviceFormat.mChannelsPerFrame,
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(MemoryLayout<Float32>.size) * deviceFormat.mChannelsPerFrame,
            mChannelsPerFrame: deviceFormat.mChannelsPerFrame,
            mBitsPerChannel: 32,
            mReserved: 0
        )

        AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat,
                             kAudioUnitScope_Output, 1,
                             &callbackFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))

        // 6. Configure output format (16kHz mono Int16 for WAV)
        outputFormat = AudioStreamBasicDescription(
            mSampleRate: targetSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0
        )

        // 7. Pre-allocate buffers
        let maxFrames: UInt32 = 4096
        let bufferSamples = maxFrames * deviceFormat.mChannelsPerFrame
        renderBuffer = .allocate(capacity: Int(bufferSamples))
        renderBufferSize = bufferSamples

        let maxOutputFrames = UInt32(Double(maxFrames) * (targetSampleRate / deviceFormat.mSampleRate)) + 1
        conversionBuffer = .allocate(capacity: Int(maxOutputFrames))
        conversionBufferSize = maxOutputFrames

        // 8. Set input callback
        var callbackStruct = AURenderCallbackStruct(
            inputProc: inputCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        AudioUnitSetProperty(au, kAudioOutputUnitProperty_SetInputCallback,
                             kAudioUnitScope_Global, 0,
                             &callbackStruct, UInt32(MemoryLayout<AURenderCallbackStruct>.size))

        // 9. Create output WAV file
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("zhiyin_\(UUID().uuidString).wav")

        var fileRef: ExtAudioFileRef?
        guard ExtAudioFileCreateWithURL(url as CFURL, kAudioFileWAVEType,
                                        &outputFormat, nil,
                                        AudioFileFlags.eraseFile.rawValue,
                                        &fileRef) == noErr else {
            throw RecorderError.setupFailed("Failed to create output file")
        }
        audioFile = fileRef
        ExtAudioFileSetProperty(fileRef!, kExtAudioFileProperty_ClientDataFormat,
                                UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
                                &outputFormat)

        // 10. Initialize and start
        guard AudioUnitInitialize(au) == noErr else {
            throw RecorderError.setupFailed("Failed to initialize AudioUnit")
        }
        guard AudioOutputUnitStart(au) == noErr else {
            throw RecorderError.setupFailed("Failed to start AudioUnit")
        }

        self.audioUnit = au
        self.tempURL = url
        self.isRecording = true
        print("AudioRecorder: AUHAL recording started")
    }

    private func stopAudioUnit() {
        if let unit = audioUnit {
            AudioOutputUnitStop(unit)
            AudioComponentInstanceDispose(unit)
            audioUnit = nil
        }
        if let file = audioFile {
            ExtAudioFileDispose(file)
            audioFile = nil
        }
        renderBuffer?.deallocate()
        renderBuffer = nil
        renderBufferSize = 0
        conversionBuffer?.deallocate()
        conversionBuffer = nil
        conversionBufferSize = 0
        isRecording = false
    }

    // MARK: - Device Resolution

    private func resolveTargetDevice() -> AudioDeviceID {
        let deviceUID = UserDefaults.standard.string(forKey: "inputDeviceUID") ?? "default"

        if deviceUID == "default" || deviceUID.isEmpty {
            // Get system default
            var defaultID: AudioDeviceID = 0
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultInputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                       &address, 0, nil, &size, &defaultID)
            print("AudioRecorder: Using system default input device (ID: \(defaultID))")
            return defaultID
        }

        // Resolve UID to device ID
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: CFString = deviceUID as CFString
        let status = withUnsafeMutablePointer(to: &uid) { uidPtr in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                       &address,
                                       UInt32(MemoryLayout<CFString>.size),
                                       uidPtr, &size, &deviceID)
        }

        if status == noErr, deviceID != 0 {
            print("AudioRecorder: Resolved device '\(deviceUID)' → ID \(deviceID)")
            return deviceID
        }

        // Device no longer available — clear saved preference and fall back to system default
        print("AudioRecorder: Could not find device '\(deviceUID)', falling back to system default")
        UserDefaults.standard.removeObject(forKey: "inputDeviceUID")

        var defaultID: AudioDeviceID = 0
        var defaultSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var defaultAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                   &defaultAddress, 0, nil, &defaultSize, &defaultID)
        print("AudioRecorder: Using system default input device (ID: \(defaultID))")
        return defaultID
    }

    // MARK: - Audio Callback

    private let inputCallback: AURenderCallback = { (inRefCon, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, _) -> OSStatus in
        let recorder = Unmanaged<AudioRecorder>.fromOpaque(inRefCon).takeUnretainedValue()
        return recorder.handleInput(ioActionFlags: ioActionFlags, inTimeStamp: inTimeStamp,
                                    inBusNumber: inBusNumber, inNumberFrames: inNumberFrames)
    }

    private func handleInput(
        ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        inTimeStamp: UnsafePointer<AudioTimeStamp>,
        inBusNumber: UInt32,
        inNumberFrames: UInt32
    ) -> OSStatus {
        guard let au = audioUnit, isRecording, let renderBuf = renderBuffer else { return noErr }

        let channelCount = deviceFormat.mChannelsPerFrame
        let requiredSamples = inNumberFrames * channelCount
        guard requiredSamples <= renderBufferSize else { return noErr }

        let bytesPerFrame = UInt32(MemoryLayout<Float32>.size) * channelCount
        var bufferList = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: channelCount,
                mDataByteSize: inNumberFrames * bytesPerFrame,
                mData: renderBuf
            )
        )

        let status = AudioUnitRender(au, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, &bufferList)
        guard status == noErr else { return status }

        // Convert and write to file + accumulate for streaming
        convertAndProcess(inputBuffer: &bufferList, frameCount: inNumberFrames)

        return noErr
    }

    private func convertAndProcess(inputBuffer: inout AudioBufferList, frameCount: UInt32) {
        guard let file = audioFile, let outputBuf = conversionBuffer else { return }

        let inputChannels = deviceFormat.mChannelsPerFrame
        let inputSampleRate = deviceFormat.mSampleRate
        let ratio = targetSampleRate / inputSampleRate
        let outputFrameCount = UInt32(Double(frameCount) * ratio)

        guard outputFrameCount > 0, outputFrameCount <= conversionBufferSize else { return }
        guard let inputData = inputBuffer.mBuffers.mData else { return }

        let inputSamples = inputData.assumingMemoryBound(to: Float32.self)

        // Also accumulate Float32 samples for streaming
        samplesLock.lock()

        if inputSampleRate == targetSampleRate {
            // Direct conversion
            for i in 0..<Int(frameCount) {
                var sample: Float32 = 0
                for ch in 0..<Int(inputChannels) {
                    sample += inputSamples[i * Int(inputChannels) + ch]
                }
                sample /= Float32(inputChannels)
                let scaled = max(-32768.0, min(32767.0, sample * 32767.0))
                outputBuf[i] = Int16(scaled)
                accumulatedSamples.append(sample)
                capturedPeak = max(capturedPeak, abs(sample))
                capturedSampleCount += 1
            }
        } else {
            // Sample rate conversion with linear interpolation
            for i in 0..<Int(outputFrameCount) {
                let inputIndex = Double(i) / ratio
                let idx1 = min(Int(inputIndex), Int(frameCount) - 1)
                let idx2 = min(idx1 + 1, Int(frameCount) - 1)
                let frac = Float32(inputIndex - Double(idx1))

                var sample: Float32 = 0
                for ch in 0..<Int(inputChannels) {
                    let s1 = inputSamples[idx1 * Int(inputChannels) + ch]
                    let s2 = inputSamples[idx2 * Int(inputChannels) + ch]
                    sample += s1 + frac * (s2 - s1)
                }
                sample /= Float32(inputChannels)
                let scaled = max(-32768.0, min(32767.0, sample * 32767.0))
                outputBuf[i] = Int16(scaled)
                accumulatedSamples.append(sample)
                capturedPeak = max(capturedPeak, abs(sample))
                capturedSampleCount += 1
            }
        }

        samplesLock.unlock()

        // Write Int16 PCM to WAV file
        var outputBufferList = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: outputFrameCount * 2,
                mData: outputBuf
            )
        )
        ExtAudioFileWrite(file, outputFrameCount, &outputBufferList)
    }

    // MARK: - Error

    private enum RecorderError: Error {
        case audioUnitNotFound
        case setupFailed(String)
    }
}
