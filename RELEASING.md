# Releasing rspec-tracer

Maintainer notes for cutting a release. The repository is trunk-based:
releases are annotated tags on `main`, and the tag push does the
publishing. Everything below assumes a clean checkout of `main` with
the pinned Ruby active (`.ruby-version` via rbenv).

## Tag-cut procedure

1. **Run the preflight gate.**

   ```sh
   task release:preflight
   ```

   Fix every `FAIL` item (they exit the task nonzero) and work through
   every `VERIFY-MANUALLY` block: hardcoded version strings in docs
   and code comments, forward version promises, the README maintenance
   policy, and the CHANGELOG/VERSION consistency check.

2. **Cut the CHANGELOG block.** Rename `## [Unreleased]` to
   `## [X.Y.Z] - YYYY-MM-DD` and add a fresh empty `## [Unreleased]`
   heading above it. Prune empty subsections; the block should read as
   release notes on its own.

3. **Bump the version.** Set `RSpecTracer::VERSION` in
   `lib/rspec_tracer/version.rb` to `X.Y.Z`. The tag must match this
   constant exactly (minus the leading `v`); the release workflow
   refuses to publish on a mismatch. Update any install snippets the
   preflight flagged in step 1.

4. **Run the full local pipeline.**

   ```sh
   task ci
   ```

5. **Open a PR** with the CHANGELOG cut and version bump, get it green
   in CI, and merge it to `main`. Never push the bump directly.

6. **Tag the merge commit on `main` and push the tag.**

   ```sh
   git checkout main && git pull
   git tag -a vX.Y.Z -m vX.Y.Z
   git push origin vX.Y.Z
   ```

   The tag push triggers `.github/workflows/release.yml`, which
   validates the tag against `RSpecTracer::VERSION`, builds the gem,
   pushes it to RubyGems (via the `RUBYGEMS_API_KEY` secret), and
   creates the GitHub release. Pre-release flavors
   (`vX.Y.Z.<flavor>.N`) use the same flow; RubyGems hides them from
   plain `gem install` unless `--pre` is passed.

## Post-tag observation checklist

- [ ] The `release` workflow run is green and the GitHub release
      exists with the expected notes.
- [ ] The gem is installable from RubyGems in a clean directory:
      `gem install rspec-tracer -v X.Y.Z` (add `--pre` for
      pre-release versions), then `ruby -e 'require "rspec_tracer"'`.
- [ ] The next nightly soak run is green.
- [ ] No new Dependabot or code-scanning alerts appeared after the
      release commit.

If publishing fails midway (for example RubyGems accepted the gem but
the GitHub release step failed), do not retag; the tag and the gem
version are already immutable. Do not reach for "Re-run failed jobs"
either: it cannot recover this state, for two reasons.

- A re-run executes the whole `publish` job from the top, including
  `gem push`. RubyGems rejects a repush of an already-published
  version with a nonzero exit, so the re-run fails again before it
  ever reaches the Create-GitHub-release step.
- Re-runs use the workflow file from the tagged commit, so a workflow
  fix cannot take effect on a re-run for the same tag. Workflow fixes
  only apply to future tag pushes.

Instead, create the GitHub release manually, mirroring the body
template in `.github/workflows/release.yml` (add `--prerelease` for
pre-release flavors):

````sh
gh release create vX.Y.Z --title vX.Y.Z --notes "$(cat <<'EOF'
See [CHANGELOG.md](https://github.com/avmnu-sng/rspec-tracer/blob/main/CHANGELOG.md) for the full release notes.

Install:

```
gem install rspec-tracer -v X.Y.Z
```
EOF
)"
````
