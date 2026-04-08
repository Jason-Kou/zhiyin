# ZhiYin 知音

> Lightning-fast voice input for macOS. Press, speak, press again — done.

<p align="center">
  <img src="assets/icon-1024.png" width="128" alt="ZhiYin">
</p>

<p align="center">
  <a href="README.zh-CN.md">中文</a> ·
  <a href="https://github.com/Jason-Kou/zhiyin/releases">Download</a> ·
  <a href="https://x.com/AgentLabX">@AgentLabX</a>
</p>

---

ZhiYin is a macOS menu-bar app for lightning-fast voice input. Supports **14 languages** with local MLX models on Apple Silicon — no cloud, no latency. Press a key, speak, press again — text appears at your cursor in any app.

## Features

- **Push-to-talk** — Hold `Option+Space`, speak, release to transcribe
- **14 languages** — Chinese, English, Japanese, Korean, Cantonese, and more
- **Auto language detection** — Let the model identify the language automatically
- **Two STT models** — FunASR (default, optimized for Chinese) or Whisper Large v3 Turbo (99 languages)
- **Traditional Chinese output** — Optional Simplified ↔ Traditional conversion
- **Blazing fast** — ~0.5s transcription powered by MLX on Apple Silicon
- **100% offline** — All processing on your Mac, nothing leaves the device
- **System-wide** — Works in any app that accepts text input
- **Context aware** — Captures selected text and browser URL for smarter results
- **Personal dictionary** — Custom term corrections for your domain
- **Free forever** — No trial timer, no expiration

## Install

### Download

Grab the latest `.dmg` from [Releases](https://github.com/Jason-Kou/zhiyin/releases).

### Build from source

```bash
git clone https://github.com/Jason-Kou/zhiyin.git
cd zhiyin
./scripts/install.sh    # sets up Python venv + dependencies
./scripts/run-dev.sh    # builds and launches
```

**Requirements**: macOS 14.0+, Apple Silicon (M1/M2/M3/M4/M5), Python 3.10+

## Usage

1. Launch ZhiYin — it appears in your menu bar
2. Grant **Microphone** and **Accessibility** permissions when prompted
3. Wait for the status to show "Ready" (model loads in ~10-30s on first launch)
4. Hold **Option+Space** and speak
5. Release — transcribed text is pasted at the cursor

### Keyboard shortcuts

| Shortcut | Action |
|----------|--------|
| Option+Space (hold) | Start recording |
| Option+Space (release) | Stop and transcribe |
| Cmd+, | Open settings |
| Cmd+Q | Quit |

## Free vs Pro

Free tier includes **50 transcriptions per day** with full voice input functionality.

**Pro** ($12, one-time) unlocks unlimited transcriptions.

## Comparison

| | **ZhiYin** | **macOS Dictation** | **Superwhisper** | **VoiceInk** | **WeChat Voice Input** |
|---|---|---|---|---|---|
| Languages | 14 | Limited | 100+ (Whisper) | 100+ (Whisper) | Chinese + a few |
| Offline | Yes | Partial (on-device available) | Yes | Yes | No (requires internet) |
| Latency | ~0.5s | ~1-2s | ~1s | ~1s | Slow on long audio |
| Traditional Chinese output | Yes (toggle) | Separate language pack | No | No | Yes |
| Personal dictionary | Yes | No | No | No | No |
| System-wide | Yes | Yes | Yes | Yes | Yes |
| Price | Free / $12 Pro | Free | $10/mo | $25 | Free |

## Tech stack

| Component | Technology |
|-----------|------------|
| STT engine | [FunASR MLX](https://github.com/FunAudioLLM/SenseVoice) (Alibaba DAMO) |
| Runtime | MLX on Apple Silicon (Neural Engine + GPU) |
| Frontend | Swift (SwiftUI + AppKit) |
| Backend | Python (FastAPI + uvicorn) |
| Audio | AVAudioEngine, 16kHz mono |

## Project structure

```
zhiyin/
├── ZhiYin/Sources/     # Swift app
│   ├── App/            # Entry point, AppDelegate
│   ├── Audio/          # Recording
│   ├── Input/          # Hotkey, text injection
│   ├── License/        # Usage tracking, license
│   ├── STT/            # Speech-to-text client
│   └── UI/             # Settings, overlays
├── python/             # Python STT server
├── scripts/            # Build, install, packaging
└── assets/             # App icon
```

## License

GPL-3.0 — see [LICENSE](LICENSE).

---

**ZhiYin** — *knows your voice*
