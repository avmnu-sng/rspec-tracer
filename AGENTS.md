# AGENTS.md

AI coding agents working in this repo: start with
[`CLAUDE.md`](CLAUDE.md). Everything there applies regardless of which
assistant is running. This file only adds agent-specific reminders
that are easy to miss.

## `docs/revamp/` is local-only — never commit it

The `docs/revamp/` tree is the maintainer's internal 2.0 planning
material. It is listed in [`.gitignore`](.gitignore) and must stay
there.

- **Do not** stage or commit any path under `docs/revamp/`.
- **Do not** copy, paraphrase, or quote its contents into files that
  *are* committed (README, CHANGELOG, CLAUDE.md, commit messages, PR
  descriptions, `.github/` templates). The revamp plan must not leak
  into the repo.
- When the maintainer hands you a session brief as context
  ("read `docs/revamp/sessions/M3.2-*.md`"), treat it as conversation
  input only. The resulting PR must stand on its own.
- If `docs/revamp/` is missing on your clone, don't re-create it —
  ask the maintainer.

## Work shape

- One session = one PR-sized deliverable. Don't scope-creep.
- Every acceptance criterion must be mechanically checkable.
- Graceful degradation always — never propagate a tracer failure into
  the user's test suite.
- Maximum supported surface — drop something only for a genuine
  technical limitation, not "effort".

## Dev loop

Use [Task](https://taskfile.dev/) commands, not `rake`. The legacy
`bundle exec rake` path still exists for cucumber but is removed in
2.0.0.

- `task check` — fast feedback loop (lint + unit specs + smoke
  benchmark). Must stay under ~10 s.
- `task ci` — full local CI equivalent.
- `task --list` — full catalog.

Tool versions are pinned in `Taskfile.yml`'s `vars:` block; bump
them in one place.

## Editing conventions

- Prefer editing existing files over creating new ones.
- Never add features, refactors, or abstractions beyond what the
  task requires.
- Default to no comments. Only comment when the *why* is non-obvious.
- Don't introduce `--no-verify`, destructive git operations, or
  backwards-compatibility shims without an explicit instruction.

## Before declaring a session complete

Run `task check` locally and confirm green. If the session has local
handoff-notes or index updates that the maintainer tracks, follow
them through — leaving them half-done breaks the next session's
diff-against-reality pass.
