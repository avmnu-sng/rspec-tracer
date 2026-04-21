<!--
Replace this block with a 1-3 sentence summary of what the PR does
and why. A reviewer should be able to skim and understand.
-->

## Summary

<!-- what changed, why -->

## Test plan

<!-- how you verified this -->

## Checklist

- [ ] Single subject — unrelated changes split into separate PRs.
- [ ] Branch is up to date with `main`.
- [ ] Related commits squashed; commit messages are
      [clear](https://chris.beams.io/posts/git-commit/).
- [ ] Added or updated tests for the behaviour change.
- [ ] `task ci` passes locally (or, for docs-only, `task lint:all`).
- [ ] Public behaviour changes documented (README, YARD, CHANGELOG
      fragment where applicable).
- [ ] If performance-sensitive: `task benchmark:full` output
      reviewed; `benchmark/ratchet.json` updated with justification
      in the commit message when thresholds intentionally move.
