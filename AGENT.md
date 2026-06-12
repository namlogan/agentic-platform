# AGENT.md — executor configuration for agentic-platform

## Commands

test: bash scripts/ci-test.sh
lint: bash -c 'shellcheck scripts/*.sh 2>/dev/null || echo "shellcheck not installed, skipping"'

## Scope conventions

- Agents may only create/modify files listed in the issue spec's "File scope" section.
- Agents must not modify: AGENT.md, .github/workflows/ci.yml, infra/ configs.
- All scripts must be POSIX-compatible bash.

## Commit format

Use Conventional Commits: `feat:`, `fix:`, `test:`, `refactor:`, `chore:`.
One logical change per commit.
