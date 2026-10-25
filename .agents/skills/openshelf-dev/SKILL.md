---
name: openshelf-dev
description: Develop OpenShelf safely. Use when adding a storage provider, changing pricing/quota/cost logic, editing the Swift or Tauri apps, or preparing a push. Covers the provider checklist, tests and the pre-push secret scan.
---

# OpenShelf development

Read `AGENTS.md` first.

## Add a storage provider

1. `Sources/OpenShelf/Storage.swift`: add a `Provider` case (title, backend, platform name, free tier, egress note, pricing).
2. `Sources/OpenShelf/AddStorage.swift`: guided setup fields and help text.
3. `desktop/src-tauri/src/providers.rs`: mirror the provider.
4. `Tests/CoreChecks/main.swift`: cover descriptor, pricing and persistence.
5. README provider list and `docs/cloud-setup/` guide.

## Verify

- `./scripts/test-core.sh`, `swift build`, and `cargo test` in `desktop/src-tauri`.
- Say plainly what could not be tested (for example live cloud APIs without credentials).

## Before pushing

Scan changed files for secrets and personal data:

```
git ls-files -m -o --exclude-standard | xargs grep -lE "BEGIN [A-Z ]*PRIVATE KEY|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{30,}|gh[pous]_[0-9A-Za-z]{30,}|/Users/"
```

No output means clean. Keep scratch files in `.local/<task-name>/artifacts/`.
