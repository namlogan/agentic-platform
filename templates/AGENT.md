# AGENT.md — executor configuration for this repo
#
# Copy this file to the root of each managed project repo.
# The orchestrator reads it to know how to test, lint, and scope agent work.

## Commands

test: npm test          # replace with your actual test command
lint: npm run lint      # replace with your actual lint command

## Scope conventions

- Agents may only create/modify files listed in the issue spec's "File scope" section.
- Agents must not modify: package-lock.json without updating package.json, CI config, AGENT.md itself.

## Commit format

Use Conventional Commits: `feat:`, `fix:`, `test:`, `refactor:`, `chore:`.
One logical change per commit.
