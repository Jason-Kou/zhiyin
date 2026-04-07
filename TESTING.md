# Testing Checklist — ZhiYin v0.1.0

## Setup
- [ ] `./scripts/install.sh` completes without errors
- [ ] Python venv created with all dependencies
- [ ] Model downloaded successfully

## App Lifecycle
- [ ] App starts via `./scripts/run-dev.sh`
- [ ] Menu bar icon (🎤) appears
- [ ] Python STT server auto-starts
- [ ] `/health` returns `{"status":"ok","model_loaded":true}`
- [ ] App quits cleanly with ⌘Q (Python server also stops)

## Voice Input
- [ ] Hold Option+Space → recording starts
- [ ] Menu bar icon animates during recording
- [ ] Start-recording sound plays
- [ ] Release Option+Space → recording stops
- [ ] Stop-recording sound plays
- [ ] Transcribed text appears at cursor position

## Recognition Quality
- [ ] Chinese speech recognized accurately
- [ ] English speech recognized accurately
- [ ] Chinese-English mixed speech handled
- [ ] Auto-punctuation works
- [ ] Latency < 1s on Apple Silicon

## Error Handling
- [ ] Microphone permission denied → shows alert
- [ ] Accessibility permission missing → shows guidance
- [ ] Python server crash → auto-restart + status update
- [ ] Empty audio → no crash, graceful handling
- [ ] Very long audio → handled without timeout

## Packaging
- [ ] `./scripts/make-dmg.sh` produces ZhiYin-v0.1.dmg
- [ ] DMG opens and shows app + README
- [ ] App runs after dragging to /Applications
