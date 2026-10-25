---
description: Security review of the changes about to be pushed
---

Use `.agents/skills/security-audit/SKILL.md` in guidance mode on the files changed since the last push (`git diff origin/main...HEAD` plus uncommitted changes). Do not run the full six-phase audit or create report files unless asked. Focus on credential handling, process arguments, file permissions, network calls and anything that could cost egress. Report findings by severity with file and line, and say what could not be verified. Then run the secret scan from `.agents/skills/openshelf-dev/SKILL.md`. Do not push.
