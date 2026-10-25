# AGENTS.md

Instructions for any AI coding agent (Codex, Claude Code, GitHub Copilot, Gemini CLI, Cursor and others). This file is the single source of truth; `CLAUDE.md`, `GEMINI.md` and `.github/copilot-instructions.md` only point here.

## What this is

OpenShelf mounts cloud storage as folders using rclone ("Bring Your Own Storage"). Object storage (S3, GCS, Azure, R2, B2, e2, Wasabi, Spaces) is treated as an **archive** to avoid egress costs. The UI shows usage, quota, free tier and estimated pay-as-you-go cost.

- `Sources/OpenShelf/` native macOS app (SwiftUI). Each mount is an rclone `nfsmount` launchd job, so quitting or updating the app does not stop uploads.
- `desktop/` Tauri app for Windows and Linux (Rust in `desktop/src-tauri/src`, UI in `desktop/ui`).
- `Tests/CoreChecks/main.swift` core checks; `docs/` design and verification notes.

## Commands

- Core tests: `./scripts/test-core.sh` (compiles `Storage.swift`, `Insights.swift`, `CloudInsights.swift` standalone).
- Mac build: `swift build`; app bundle: `./scripts/build-app.sh`.
- Desktop: `cd desktop/src-tauri && cargo test`.

## Rules

- `Storage.swift`, `Insights.swift` and `CloudInsights.swift` must stay UI-free (no SwiftUI/AppKit); put logic there and test it.
- The Swift toolchain here has no SwiftUI macros: use `ObservableObject`/`@StateObject`, not `@State`/`@Observable`.
- Provider data lives in both `Storage.swift` (`Provider`) and `desktop/src-tauri/src/providers.rs`; keep them in sync.
- Surgical changes: touch only what the task needs; add or update a test with each behaviour change.
- Pricing figures are approximate list prices; the UI must say "estimate".

## Security (non-negotiable)

- Never commit credentials, tokens, keys, passwords, emails, phone numbers, cloud project names or absolute home paths (`/Users/...`).
- Credentials live only in owner-only (0600) files outside the repo and never in process arguments or the connection manifest.
- Before every push, scan changed files for private-key blocks, `AKIA…`, `AIza…`, `gh[pous]_…` and `/Users/`.
- Scratch plans, todo lists and temporary artifacts go in `.local/<task-name>/artifacts/` (git-ignored).

## Skills, prompts, agents

- Skill: `.agents/skills/openshelf-dev/SKILL.md` (mirrored for Claude in `.claude/skills/`).
- Prompts: `.github/prompts/*.prompt.md` (same text is usable in any assistant).
- Review agent: `.github/agents/reviewer.agent.md` and `.claude/agents/reviewer.md`.
