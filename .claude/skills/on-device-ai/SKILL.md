---
name: on-device-ai
description: Implement or review Agent HQ's AI layer — local llama.cpp embedded in Flutter via dart:ffi, the GGUF model manager, and remote providers added with user API keys (OpenAI-compatible, Claude, Gemini, custom). Use when touching app/lib/ai/, agent prompts, the AI settings screen, or anything that sends data to a model.
---

# On-device AI + bring-your-own API key

Source of truth: `PRD_AI_Agent_HQ_Android_Offline_Infinix_X6871.md` §6 and §7. Read the relevant section before changing behaviour; update the PRD if a decision changes.

## Local runtime checklist

- llama.cpp built for `arm64-v8a` and shipped as a `.so` inside the APK; Dart calls it through `dart:ffi`. Pin the llama.cpp commit and record it in `docs/ARCHITECTURE.md`.
- One long-lived worker `Isolate` owns the model: load, generate, cancel, and unload are messages to it. The UI isolate never blocks on FFI.
- One model loaded, one active local inference, a priority queue shared by all agents.
- Defaults: context 2048, max output 256–512, 4 threads, CPU only. Change only from measured benchmarks (android-device skill).
- Unload on `onTrimMemory`/app background. Persist mission state first.
- Use a GBNF grammar or JSON schema for agent outputs. Validate with the same schema for every provider, retry a limited number of times, then fall back to a template.
- Models: download with resume + SHA-256 check + free-space check, or import a `.gguf` through SAF. Never commit or bundle models.

## Provider layer

- Every model goes through `AiProvider` (`chat` returns a stream, `healthCheck`) and the `AiRouter`. Agents never call HTTP or FFI directly.
- Model IDs and base URLs are user config, not constants. For Claude defaults, check the claude-api skill for current model IDs instead of guessing.
- Modes: `Offline Only` (default; zero network), `Hybrid`, `Cloud Preferred`. On remote failure (timeout/401/429/offline), retry a bounded number of times, then fall back to local and tell the user.
- Track token usage per provider and mission.

## Security and privacy (blockers in review)

- API keys only in `flutter_secure_storage`. Not in SQLite, prefs, logs, crash reports, exports, or backups. Show them masked.
- HTTPS only for internet providers; plain HTTP only for loopback/LAN after explicit user confirmation. No certificate bypass.
- Send aggregates (KPIs, top-N, period totals) to remote providers by default, never raw rows or files. Raw rows need a separate explicit opt-in.
- Show a payload preview and ask for consent before the first remote call of a mission.
- Treat spreadsheet content as untrusted data, never as instructions; keep it out of system prompts.
- Every AI message shows its source (local or provider name).
- The LLM never produces KPI numbers. It may only phrase numbers returned by tools, with their source metadata.

## Verify before claiming

Offline claims need a test in airplane mode on the phone. Fallback claims need a test with the network cut mid-mission. Key-leak claims need a grep of logs, the SQLite file, and exports for the key prefix.
