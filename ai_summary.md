# oc-go-cc — AI Codebase Summary

## Overview

**oc-go-cc** is a Go proxy server that sits between **Claude Code** (Anthropic's CLI coding agent) and **OpenCode Go** (a subscription-based API gateway, $5/mo) / **OpenCode Zen** (pay-as-you-go API). It intercepts Anthropic Messages API requests, transforms them to OpenAI Chat Completions format (and other formats), forwards them to OpenCode, and transforms responses back to Anthropic SSE format.

- **Language:** Go 1.25
- **Module:** `oc-go-cc`
- **License:** MIT
- **Binary:** `oc-go-cc`

---

## Architecture Flow

```
Claude Code
    │
    ▼  POST /v1/messages (Anthropic format)
    │
oc-go-cc proxy
    │
    ├── Router (scenario detection)
    ├── Fallback chain + Circuit breaker
    ├── Request Transformer (Anthropic → OpenAI/Responses/Gemini)
    │
    ▼
    │
    ├── OpenCode Go (Chat Completions API) — most models
    ├── OpenCode Zen → ClassifyEndpoint()
    │   ├── OpenAI Chat Completions — Kimi, MiMo, GLM, DeepSeek, Grok, etc.
    │   ├── Anthropic Messages — Qwen, Claude
    │   ├── OpenAI Responses — GPT-5 series
    │   └── Google Gemini — Gemini models
    │
    ▼
    │
    ├── Response Transformer (OpenAI/Responses/Gemini → Anthropic)
    └── Stream Transformer (SSE format conversion in real-time)
```

---

## File-by-File Breakdown

### Entry Point

| File | Purpose |
|------|---------|
| `cmd/oc-go-cc/main.go` | Cobra CLI: `serve`, `stop`, `status`, `init`, `validate`, `check`, `models`, `autostart` commands. PID file management. Default config template. Background daemon support. |

### Configuration (`internal/config/`)

| File | Purpose |
|------|---------|
| `config.go` | All config types: `Config` (API keys, host/port, models map, fallbacks, model_overrides, OpenCodeGo/Zen sub-configs), `ModelConfig` (provider, model_id, temperature, max_tokens, context_threshold, reasoning_effort, thinking, vision, anthropic_tools_disabled). `EffectiveAPIKeys()` merges `APIKey` and `APIKeys` fields. |
| `loader.go` | `Load()` → `LoadFromPath()` → `loadJSON()` → `interpolateEnvVars(${VAR})` → `applyEnvOverrides(OC_GO_CC_*)` → `applyDefaults()` → `validate()`. Rejects empty API keys and unresolved `${VAR}` placeholders. |
| `atomic.go` | `AtomicConfig`: lock-free thread-safe config via `atomic.Pointer`. `Reload()` preserves errors. `OnReload()` callbacks with panic recovery — invoked **before** atomic swap. |
| `watcher.go` | `WatchConfig()`: fsnotify on config directory, handles rename-save editors, 500ms debounce, SIGHUP support. |

### Server (`internal/server/`)

| File | Purpose |
|------|---------|
| `server.go` | HTTP server with mux: `POST /v1/messages`, `POST /v1/messages/count_tokens`, `GET /health`. Zero `WriteTimeout` for SSE. 120s ReadTimeout, 300s IdleTimeout. Injects: token counter, metrics, OpenCode client, model router, fallback handler, handlers. Config hot-reload callback re-reads log level. |

### Client (`internal/client/`)

| File | Purpose |
|------|---------|
| `opencode.go` | `OpenCodeClient`: HTTP client (100 max idle, 20/host, 90s idle). 7 key methods: `ChatCompletion`/`ChatCompletionNonStreaming`/`GetStreamingBody` (OpenAI Chat Completions), `SendAnthropicRequest` (raw Anthropic), `ResponsesCompletion`/`GetResponsesStreamingBody` (OpenAI Responses), `GeminiCompletion`/`GetGeminiStreamingBody` (Google Gemini). Classification: `IsAnthropicModel` (only qwen3.7-max on Go), `ClassifyEndpoint` (routes to correct Zen endpoint), `isGeminiModel`, `isResponsesModel`. `nextAPIKey()` round-robin. `StreamIdleTimeout()` per-provider. |

### Handlers (`internal/handlers/`)

| File | Purpose |
|------|---------|
| `messages.go` | `MessagesHandler`: POST /v1/messages. Rate limiter (100 req/min per IP). Request dedup (500ms via SHA256). Model chain building: overrides → scenario routing → deduped safety-net chain. Streaming: SSE headers, 3s heartbeat, model chain iteration. Non-streaming: `ExecuteWithFallback` multi-endpoint. Key helpers: `sanitizeAnthropicBody` (removes `type` field tool format incompatibility), `replaceModelInRawBody`, `extractTextFromBlocks`, `sendError`. |
| `health.go` | `HealthHandler`: GET /health (metrics + circuit breaker states), POST /v1/messages/count_tokens. |
| `token_count.go` | Token counting helpers using tiktoken. |

### Router (`internal/router/`)

| File | Purpose |
|------|---------|
| `scenarios.go` | `DetectScenario()`: priority — `long_context` (>80K tokens) > `complex` (architectural patterns, tool operations) > `think` (reasoning keywords) > `background` (simple read-only) > `default`. `RouteForStreaming()` downgrades to fast models (Qwen3.6 Plus) for better TTFT. |
| `model_router.go` | `ModelRouter`: `Route()`, `RouteForStreaming()`, `RouteWithOverride()`. `RouteResult` with Primary, Fallbacks, Scenario. `resolveRequestedModel()`. `GetModelChain()` builds ordered attempt list. |
| `fallback.go` | `CircuitBreaker`: closed → open (3 failures) → half-open (30s) → closed (3 successes). `FallbackHandler.ExecuteWithFallback()` tries models sequentially, respects breaker, distinguishes retryable (5xx, network) vs non-retryable (4xx) errors. |

### Transformer (`internal/transformer/`)

| File | Purpose |
|------|---------|
| `request.go` | `RequestTransformer.TransformRequest()` (Anthropic → OpenAI Chat Completions): message transforms, tool transforms, cache_control, thinking/reasoning_effort resolution. `HasThinkingBlocks()` (deep inline thinking on tool_use). DeepSeek safety guard (disables thinking when history lacks `reasoning_content`). Cache: preserve for DeepSeek, skip for Kimi, strip others. `TransformToResponses()` and `TransformToGemini()`. Temperature constraint for kimi-k2.7-code (forces 1.0). |
| `response.go` | `ResponseTransformer.TransformResponse()` (OpenAI → Anthropic): content block mapping (reasoning→thinking, tool_calls→tool_use, text). Finish reason mapping. Cache-aware token accounting: `input_tokens = prompt_tokens - cache_hit - cache_miss`, clamped to non-negative. `TransformResponsesResponse()`, `TransformGeminiResponse()`, `TransformErrorResponse()`. |
| `stream.go` | `StreamHandler`: `ProxyStream()` (OpenAI SSE → Anthropic SSE), `ProxyResponsesStream()`, `ProxyGeminiStream()`. Event sequence: `message_start` → `content_block_start` → `content_block_delta(s)` → `content_block_stop` → `message_delta` → `message_stop`. Reasoning→thinking_delta, tool_calls→input_json_delta, text→text_delta. Fast path (string search before JSON parse). Ghost chunk handling for recycled tool call indices. Per-Read idle deadline via `http.ResponseController.SetReadDeadline`. Sentinel errors: `ErrClientDisconnected`, `ErrStreamIdle`. |

### Types (`pkg/types/`)

| File | Purpose |
|------|---------|
| `anthropic.go` | `MessageRequest` (polymorphic System, Thinking), `Message`, `ContentBlock` (text/tool_use/tool_result/thinking/image), `Tool`, `ToolResult`, `MessageResponse`, `Usage`, `MessageEvent`, `Delta`, `APIError`. Custom `MarshalJSON` per type strips irrelevant fields. `SystemText()`, `ContentBlocks()` accessors. `Validate()`. |
| `openai.go` | `ChatCompletionRequest` (ReasoningEffort, Thinking, StreamOptions), `ChatMessage` (ReasoningContent, ToolCalls, CacheControl), `ToolCall`, `FunctionCall`, `ToolDef`, `FunctionDef`, `ChatCompletionResponse`, `Choice`, `UsageInfo`, `ChatCompletionChunk`. `TextContent()`, `ContentText()` helpers. |
| `zen.go` | `ResponsesRequest`/`Response` (OpenAI Responses API), `GeminiRequest`/`Response` (Google Gemini), with streaming chunk types. |

### Other Packages

| File | Purpose |
|------|---------|
| `internal/metrics/metrics.go` | Atomic counters: requests received/streamed/success/failed/upstream/rate-limited/deduped. Latency tracking (1000 samples, p95/p99). JSON snapshot. |
| `internal/middleware/middleware.go` | `RequestDeduplicator` (SHA256, 500ms window), `RateLimiter` (token bucket, 100 req/min per IP), `RequestIDGenerator`. |
| `internal/token/counter.go` | tiktoken `cl100k_base` counter. `CountMessages()` with system overhead (+5) and per-message formatting (+5). Cache dir: `~/.cache/oc-go-cc/tiktoken`. |
| `internal/daemon/` | Platform daemon: background fork, PID management. `autostart_unix.go` (Linux .desktop, macOS launchd), `autostart_windows.go` (registry). |

### Build & Deploy

| File | Purpose |
|------|---------|
| `Makefile` | build, run, test (`-race`), lint (gofmt + golangci-lint), clean, install, dist (6 platforms), docker-up, docker-stop. |
| `Dockerfile` | Two-stage: `golang:1.24-alpine` build, `alpine:3.21` runtime, non-root user, HEALTHCHECK. |
| `scripts/e2e-test.sh` | End-to-end: build → start → test 6 models with tool requests. |
| `.github/workflows/ci.yml` | Test, vet, lint, build across Go versions. |
| `.github/workflows/release.yml` | Validate → release with AI changelog → Homebrew tap update → Scoop bucket update. |

---

## Endpoint Classification (ClassifyEndpoint)

| Endpoint Type | Models |
|---------------|--------|
| `EndpointChatCompletions` | minimax-m2.5, minimax-m2.7, minimax-m3, kimi-k2.6, kimi-k2.5, mimo-v2.5, mimo-v2.5-pro, glm-5.1, deepseek-*, grok-*, big-pickle, north-*, unknown (default) |
| `EndpointAnthropic` | qwen3.5-plus, qwen3.6-plus, qwen3.7-plus, qwen3.7-max, claude-* |
| `EndpointGemini` | gemini-* |
| `EndpointResponses` | gpt-5*, gpt-5.4*, gpt-5.5* |

---

## Scenario Detection Priority

1. **long_context** (>80K tokens) → MiniMax (1M context)
2. **complex** (architectural, tools ops keywords) → GLM-5.1
3. **think** (reasoning keywords in system) → GLM-5
4. **background** (read-only, no tools) → Qwen3.5 Plus
5. **default** → Kimi K2.6

Streaming downgrades to **fast** (Qwen3.6 Plus).

---

## Model Config Fields

| Field | Description |
|-------|-------------|
| `provider` | `"opencode-go"` or `"opencode-zen"` |
| `model_id` | Model identifier string |
| `temperature` | Sampling temperature |
| `max_tokens` | Max tokens in response |
| `context_threshold` | Token threshold for scenario routing |
| `reasoning_effort` | For reasoning models |
| `thinking` | JSON raw message for thinking config |
| `vision` | Whether model supports vision |
| `anthropic_tools_disabled` | If true, forces through Chat Completions transform (avoids Anthropic tool format incompatibility) |

---

## Circuit Breaker

- **State:** closed → open → half-open → closed
- **Open threshold:** 3 consecutive failures
- **Half-open wait:** 30 seconds
- **Close threshold:** 3 consecutive successes in half-open
- **Retryable errors:** 5xx, network errors
- **Non-retryable errors:** 4xx (passed through immediately)

---

## Streaming SSE Transform Sequence

```
OpenAI Chunk                        Anthropic SSE Event
─────────────────                   ───────────────────
role chunk                          message_start (with delta)
reasoning_content                   content_block_start (thinking) + deltas
text content chunk                  content_block_delta (text_delta)
tool_calls chunk                    content_block_delta (input_json_delta)
finish_reason + usage               content_block_stop + message_delta + message_stop
```

---

## Cache Control & Token Accounting

- **DeepSeek models:** preserve `cache_control` from request
- **Kimi models:** skip `cache_control` in response
- **Other models:** strip `cache_control`
- **Token accounting:** `input_tokens = prompt_tokens - cache_hit - cache_miss` with non-negative clamp

---

## Dependencies

| Dependency | Version | Purpose |
|------------|---------|---------|
| github.com/fsnotify/fsnotify | v1.10.1 | File watching for hot reload |
| github.com/pkoukk/tiktoken-go | v0.1.8 | Token counting |
| github.com/spf13/cobra | v1.8.1 | CLI framework |
| golang.org/x/sys | v0.13.0 | OS-level (daemon, signals) |
| github.com/google/uuid | — | Request IDs |

---

## Test Coverage

| Package | Test File | What's Tested |
|---------|-----------|---------------|
| `client` | `opencode_test.go` | IsAnthropicModel, Provider, IsZen, ClassifyEndpoint, isGeminiModel, isResponsesModel, nextAPIKey (round-robin, single, empty, concurrent), StreamIdleTimeout |
| `config` | `loader_test.go` | Basic load, model_overrides, env overrides, defaults, interpolation, validation, EffectiveAPIKeys |
| `config` | `atomic_test.go` | Get, Reload (success + error preservation), OnReload (single/multiple/concurrent safety) |
| `config` | `watcher_test.go` | File change detection with fsnotify |
| `handlers` | `messages_test.go` | appendUniqueModels dedup, buildModelChain (no-override, override+scenario dedup, streaming, unknown), sanitizeAnthropicBody |
| `handlers` | `health_test.go` | HandleCountTokens (content blocks, system+tools+thinking) |
| `router` | `fallback_test.go` | IsRetryableError, circuit breaker (non-retryable, retryable, mixed) |
| `router` | `scenarios_test.go` | hasComplexPattern, hasThinkingPattern, DetectScenario (all 6 scenarios), RouteForStreaming thresholds |
| `router` | `model_router_test.go` | Route (respect_requested_model), RouteWithOverride (match/no-match/nil-map/missing-fallbacks), RouteForStreaming |
| `transformer` | `request_test.go` | Reasoning/thinking matrix (18 cases), cache control (DeepSeek preserve, Kimi skip, strip), tool result ordering, vision/non-vision, temperature constraints, DeepSeek history guard, placeholder reasoning_content |
| `transformer` | `response_test.go` | Reasoning preservation with/without tool calls, empty reasoning, cache token accounting (full, partial, exceeds, no cache) |
| `transformer` | `stream_test.go` | Reasoning delta, text, tool calls, ghost chunks, finish+usage, EOF fallback stop_reason, empty reasoning, mixed content, no-duplicate message_delta, fast path, idle timeout |
| `token` | `counter_test.go` | DefaultCacheDir precedence |
| `pkg/types` | `anthropic_test.go` | ContentBlock MarshalJSON (all types, no leaked fields), SystemText, ContentBlocks, TextContent |
| `daemon` | `daemon_test.go` | PID round-trip, missing/invalid PID, executable resolution, process running |

---

## Config Example Structure

```json
{
  "api_key": "...",
  "api_keys": ["...", "..."],
  "host": "127.0.0.1",
  "port": 8080,
  "hot_reload": true,
  "enable_streaming_scenario_routing": true,
  "respect_requested_model": true,
  "models": {
    "default": { "provider": "opencode-zen", "model_id": "kimi-k2.6" },
    "complex": { "provider": "opencode-zen", "model_id": "glm-5.1" },
    "think": { "provider": "opencode-zen", "model_id": "glm-5" },
    "long_context": { "provider": "opencode-zen", "model_id": "minimax-m3" },
    "background": { "provider": "opencode-zen", "model_id": "qwen3.5-plus" },
    "fast": { "provider": "opencode-zen", "model_id": "qwen3.6-plus" }
  },
  "fallbacks": {
    "kimi-k2.6": ["qwen3.7-plus", "glm-5.1"],
    "glm-5.1": ["qwen3.7-plus"],
    "minimax-m3": ["kimi-k2.6"],
    ...
  },
  "model_overrides": { ... },
  "opencode_go": { "base_url": "https://api.opencode.ai/go", ... },
  "opencode_zen": { "base_url": "https://api.opencode.ai/zen", ... }
}
```

---

## Two Providers

| Provider | Model | Pricing | Access |
|----------|-------|---------|--------|
| **OpenCode Go** | All models | $5/month subscription | API key with subscription |
| **OpenCode Zen** | All models | Pay-as-you-go | Separate API key (or same key) |

Go provider models are all routed through OpenAI Chat Completions format. Zen models can use any of the 4 endpoint formats based on `ClassifyEndpoint()`.

---

## Key Design Decisions

1. **Config-driven model routing**: Adding a new model requires zero code changes — only config changes.
2. **Scenario routing**: Not all traffic gets the same model — context length, complexity, and system prompts determine the best model.
3. **Per-Read idle deadlines**: Streams are never killed while producing bytes. Only gaps between bytes trigger timeouts. WriteTimeout is 0 for SSE.
4. **Callback-before-swap**: OnReload callbacks run before the atomic config pointer swap, so side effects (e.g., port changes) apply before readers see new config.
5. **Ghost chunk handling**: When tool call indices are recycled between chunks, the stream transformer emits synthetic `content_block_stop`/`content_block_start` events to keep Anthropic state consistent.
6. **EOF fallback**: If a stream ends without a finish_reason but tool calls were in progress, the transformer emits `stop_reason: "tool_use"` so Claude waits for tool results instead of treating it as an error.
