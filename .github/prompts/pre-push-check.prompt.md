---
description: Run tests and the secret scan before pushing
---

Run `./scripts/test-core.sh` and `swift build`, then the secret scan from `.agents/skills/openshelf-dev/SKILL.md`. Review the changed files with `.agents/skills/security-audit/SKILL.md` in guidance mode. Report failures and anything that could not be tested. Do not push.
