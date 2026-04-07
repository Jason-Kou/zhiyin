# VAD 实时流式语音识别架构总结

> 从 ZhiYin 项目中提炼的实时语音流式处理经验，供其他项目参考。

---

## 1. 核心思路

**问题**：传统方案用滑动窗口不断重新识别最近 N 秒音频，延迟随录音时长线性增长，且文字不稳定（新音频加入后已识别文字会变）。

**解决方案**：Silero VAD 检测句子边界 → 只增量转录已完成的句段 → 文字一旦出现就稳定不变。

**效果**：
- 延迟恒定（~0.5s/句），不随录音时长增长
- 文字稳定，不会闪烁变化
- 网络流量和计算量大幅降低

---

## 2. 整体架构

```
┌─────────────────────────────────────────────────┐
│  客户端 (Swift / 任意前端)                        │
│                                                   │
│  麦克风 → AVAudioEngine → 16kHz Mono Float32      │
│       ↓                                           │
│  accumulatedSamples[] ← 持续累积                   │
│       ↓ (每 0.3s)                                  │
│  drainNewSamples() → 只取增量部分                   │
│       ↓                                           │
│  POST /stream/chunk/{session_id}  (binary float32) │
│       ↓                                           │
│  收到响应 → 更新 UI 显示已识别文字                   │
└─────────────────────────────────────────────────┘
                        ↕ HTTP
┌─────────────────────────────────────────────────┐
│  服务端 (Python FastAPI)                          │
│                                                   │
│  收到 chunk → 追加到 session.samples               │
│       ↓                                           │
│  Silero VAD 检测语音段落                            │
│       ↓                                           │
│  发现完成的句子 → FunASR 转录该段                    │
│       ↓                                           │
│  累积文字 → 返回给客户端                             │
└─────────────────────────────────────────────────┘
```

---

## 3. 关键设计模式

### 3.1 增量音频发送（客户端）

客户端维护一个 `chunkSentIndex` 指针，每次只发送新增的音频样本：

```swift
// 线程安全的增量取样
func drainNewSamples() -> [Float]? {
    samplesLock.lock()
    defer { samplesLock.unlock() }

    let total = accumulatedSamples.count
    let start = chunkSentIndex
    guard total > start else { return nil }

    let newSamples = Array(accumulatedSamples[start..<total])
    chunkSentIndex = total  // 标记已发送位置
    return newSamples.isEmpty ? nil : newSamples
}
```

**要点**：
- 音频持续累积，发送端只取 delta
- 用锁保证线程安全（录音线程写，发送线程读）
- Timer 每 0.3s 触发一次 drain + send

### 3.2 VAD 句子边界检测（服务端）

用 Silero VAD 在服务端检测语音/静音边界，判断一个句子是否说完：

```python
def run_vad(audio: np.ndarray) -> list[dict]:
    wav_tensor = torch.from_numpy(audio).float()
    timestamps = get_speech_timestamps(
        wav_tensor,
        vad_model,
        sampling_rate=16000,
        min_speech_duration_ms=250,    # 最短语音段 250ms
        min_silence_duration_ms=500,   # 500ms 静音 = 句子边界
        speech_pad_ms=100,             # 语音前后各补 100ms
        return_seconds=False,
    )
    return timestamps  # [{"start": 1600, "end": 19200}, ...]
```

**判断句子完成的逻辑**：

```python
silence_margin = int(SAMPLE_RATE * 0.3)  # 300ms

for seg in vad_segments:
    seg_end = seg["end"]
    # 句子后面有 300ms+ 的静音 → 认为这句话说完了
    if seg_end + silence_margin < len(all_samples):
        if seg_end > last_transcribed_end:
            # 新完成的句子，送去转录
            transcribe(samples[last_transcribed_end:seg_end])
```

### 3.3 Session 状态管理（服务端）

每个录音会话维护独立状态：

```python
session = {
    "samples": np.array([]),        # 累积的所有音频样本
    "vad_processed_up_to": 0,       # VAD 已处理到的位置
    "last_transcribed_end": 0,      # 已转录到的位置（样本索引）
    "transcribed_segments": [],     # [{"start", "end", "text"}, ...]
    "full_text": "",                # 拼接好的完整文字
    "version": 0,                   # 每次有新文字时 +1
}
```

### 3.4 Finalize：处理最后未完成的音频

用户松开按键时，最后一句话可能还没有足够的静音来触发 VAD 完成判定。Finalize 端点处理这个 case：

```python
@app.post("/stream/finalize/{session_id}")
async def finalize(session_id: str):
    # 1. 对全部音频跑一次 VAD
    # 2. 转录所有未处理的 VAD 段
    # 3. 如果最后还有未转录的音频，直接转录
    # 4. 清理 session
    remaining = samples[last_transcribed_end:]
    if len(remaining) >= 1600:  # 至少 0.1s
        text = transcribe(remaining)
```

---

## 4. API 设计

### 会话生命周期

| 端点 | 方法 | 说明 |
|------|------|------|
| `/stream/start` | POST | 创建新会话，返回 `session_id` |
| `/stream/chunk/{id}` | POST | 发送音频块（binary float32），返回累积文字 |
| `/stream/poll/{id}` | GET | 轮询新文字（可选，chunk 响应已含文字） |
| `/stream/finalize/{id}` | POST | 结束会话，转录剩余音频，返回最终文字 |
| `/stream/{id}` | DELETE | 取消会话 |

### Chunk 响应格式

```json
{
  "ok": true,
  "text": "你好世界",
  "version": 2,
  "segments": 2,
  "duration": 3.5
}
```

- `text`：所有已完成句子的拼接文字
- `version`：每次有新转录结果时 +1，客户端据此判断是否需要更新 UI
- `segments`：已完成的句段数

---

## 5. 关键参数一览

| 参数 | 值 | 说明 |
|------|-----|------|
| 采样率 | 16000 Hz | Silero VAD 要求，客户端服务端必须一致 |
| Chunk 发送间隔 | 0.3s | 客户端 Timer 周期 |
| VAD 最小检查量 | 0.3s (4800 样本) | 新音频不足 0.3s 时跳过 VAD |
| 静音判定阈值 | 300ms | 句子后有 300ms 静音视为完成 |
| `min_speech_duration_ms` | 250ms | 短于 250ms 的语音被忽略 |
| `min_silence_duration_ms` | 500ms | VAD 用来分割句子的静音阈值 |
| `speech_pad_ms` | 100ms | 语音前后的 padding |
| 最短可转录音频 | 0.1s (1600 样本) | 低于此长度不转录 |
| Session 超时 | 300s | 自动清理不活跃的 session |
| 转录请求超时 | 30s (chunk), 60s (finalize) | 网络超时设置 |

---

## 6. 与滑动窗口方案的对比

| 维度 | 滑动窗口 | VAD 句子边界（当前方案） |
|------|---------|----------------------|
| 延迟 | 随录音变长而增大 | 恒定 ~0.5s/句 |
| 文字稳定性 | 不稳定，新音频影响旧文字 | 稳定，句子完成后不变 |
| 计算量 | 每次重新转录窗口内所有音频 | 只转录新完成的句段 |
| 网络请求 | 2 个 Timer（chunk + preview） | 1 个 Timer（chunk，响应即含文字） |
| 用户体验 | 文字频繁闪烁变化 | 一句一句稳定出现 |
| 实现复杂度 | 简单 | 稍复杂（需要 VAD + 状态管理） |

---

## 7. 数据流时序示例

```
T=0.0s  用户按住热键 → 开始录音
        POST /stream/start → session_id="abc123"
        启动 0.3s Timer

T=0.3s  Timer 触发，drain 4800 样本
        POST /stream/chunk/abc123 (binary)
        → 服务端 VAD: 还在说话，无完成句子
        → 返回 {"text": "", "version": 0}

T=0.6s  继续发送 chunk...

T=1.2s  用户说完 "你好" 后停顿
        VAD 检测到 0-0.8s 有语音，0.8-1.2s 静音
        seg_end(0.8s) + 0.3s < 1.2s ✓ → 句子完成
        转录 samples[0:0.8s] → "你好"
        → 返回 {"text": "你好", "version": 1}
        → 客户端 UI 显示 "你好"

T=1.5s  用户继续说 "世界"...

T=2.5s  用户松开热键 → 停止录音
        发送最后一个 chunk
        POST /stream/finalize/abc123
        → 转录剩余未完成的音频 → "世界"
        → 返回 {"text": "你好世界"}
        → 粘贴到光标位置
```

---

## 8. 复用建议

如果你的项目需要实时语音流式处理，以下是可以直接复用的部分：

### 必须保持一致的
- **采样率 16kHz**：Silero VAD 的硬性要求
- **Float32 PCM 格式**：VAD 和 ASR 都要求 float32
- **Session 模型**：每次录音一个独立 session，避免状态混乱

### 可以调整的
- **Chunk 间隔**：0.2-0.5s 都可以，越短延迟越低但网络开销越大
- **静音阈值**：根据使用场景调整 `min_silence_duration_ms`
  - 口语对话：300-500ms（说话节奏快）
  - 正式演讲：500-800ms（停顿更长）
  - 指令输入：200-300ms（快速响应）
- **ASR 模型**：可换成 Whisper、Paraformer 等，VAD 层不变
- **传输方式**：HTTP 可换成 WebSocket 减少连接开销

### 注意事项
- VAD 要在服务端跑（客户端只管录音和发送）
- Finalize 必须处理"最后一句没有足够静音"的情况
- Session 要有超时清理，防止内存泄漏
- Chunk 发送失败应静默忽略，不中断录音

---

## 9. 依赖清单

### Python 服务端
```
fastapi           # HTTP 框架
uvicorn           # ASGI 服务器
numpy             # 数值计算
torch             # Silero VAD 依赖
silero_vad        # 语音活动检测
soundfile         # 音频 I/O（可选）
# + 你选择的 ASR 模型的依赖
```

### 客户端（Swift 为例）
- `AVAudioEngine`：音频采集
- `URLSession`：HTTP 请求
- `Timer`：定时发送 chunk

---

## 10. 源码参考

本项目的实现文件：

| 文件 | 说明 |
|------|------|
| `python/stt_server.py` | 服务端：VAD + ASR + Session 管理 |
| `ZhiYin/Sources/Audio/AudioRecorder.swift` | 音频采集 + 增量取样 |
| `ZhiYin/Sources/STT/SenseVoiceTranscriber.swift` | HTTP 客户端 + 流式 API 调用 |
| `ZhiYin/Sources/App/ZhiYinApp.swift` | 录音流程编排（Timer、chunk 发送） |
