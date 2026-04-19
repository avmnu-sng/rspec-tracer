# AGENTS.md

AI coding agents working in this repo: read [`CLAUDE.md`](CLAUDE.md)
first. Same rules apply regardless of which assistant is running.

Two items bear repeating here because they are easy to miss:

## `docs/revamp/` is local-only — never commit it

The `docs/revamp/` tree is internal 2.0 planning material held in the
maintainer's local worktree. It is listed in [`.gitignore`](.gitignore).

- **Do not** stage or commit any path under `docs/revamp/`.
- **Do not** copy, paraphrase, or quote its contents into files that
  *are* committed (README, CHANGELOG, CLAUDE.md, commit messages, PR
  descriptions). The revamp plan must not leak into the repo.
- Treat referenced briefs as conversation context only.

If `docs/revamp/` is missing on your clone, don't re-create it — ask the
maintainer.

## Work shape

- One session = one PR-sized deliverable. Don't scope-creep.
- Every acceptance criterion must be mechanically checkable.
- Graceful degradation always — never propagate a tracer failure into
  the user's test suite.
- Maximum supported surface — drop something only for a genuine
  technical limitation, not "effort".

## Dev loop

- `bundle exec rake` — full default (lint + unit specs + cucumber
  coverage runs). A Taskfile with a 10-second `task check` is planned
  but not yet in place.
