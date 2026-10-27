# Changelog

All notable changes to critique.nvim. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and versions follow [Semantic Versioning](https://semver.org/). Releases are git tags (`v0.2.0`); with
lazy.nvim, `version = '*'` follows them.

## [0.2.2] - 2026-10-27

### Added

- A demo of the 0.2 features in the README (`demo/features.gif`), with the scripts that stage and record
  it (`demo/features-setup.sh`, `demo/features.tape`).

### Fixed

- Reopening a PR failed with "Your local changes to the following files would be overwritten by
  checkout" when edits had been saved in its checkout (by `:w` before 0.2, an auto-save plugin, or with
  `auto_suggest` off) and new commits changed those files. critique now stashes the edits, says so, and
  tells you how to get them back. Opening GitHub PRs has offline tests now.
- With `:Critique since` on, the file list's viewed count counted all of the review's files ("2/4
  viewed" over a list of 3). It counts the files listed now.

## [0.2.1] - 2026-10-27

### Documentation

- The README advertises 0.2.0's features at the top and walks through them in the GitHub and agent
  sections. Both the README and `:help critique` gain their keymaps, how they work, troubleshooting
  (`:w` not saving, auto-save plugins, `:Critique since` messages), and limits.
- Fixed: the README and help said outdated GitHub threads are hidden. Since 0.2.0 they show at their
  old line, marked outdated.

## [0.2.0] - 2026-10-27

### Added

- **Suggestions from your edits.** Edit a file in a review and `:w`. Nothing is written to disk: a
  window previews your edits as suggestions (it scrolls for big edits), `y` posts them and `n` cancels.
  On GitHub they're suggestions in your pending review that the PR's author can commit. In a local
  review they're drafts for the agent until you submit, or sent right away in a live review. In local
  reviews, `:w!` writes the file. Auto-save plugins that save on a timer are ignored.
- `:Critique suggest` previews and posts your edits on demand, for when `:w` should save as usual.
- **Options**, via `require('critique').setup({...})` or lazy.nvim's `opts`. The first is
  `auto_suggest` (default on): whether `:w` in a review file offers suggestions.
- **`:Critique threads`** lists the open threads in the quickfix list, in file order, tagged
  `needs your reply`, `pending`, or `outdated`; `]q` / `[q` go through them. Resolved threads stay
  (marked) until you list them again, so `]q` doesn't lose your place.
- **`:Critique viewed`** marks a file viewed and moves on to the next unviewed one. The file list shows
  ✓ and "3/8 viewed"; a viewed file that changes afterwards shows ●. On GitHub it's the PR's own
  "Viewed" checkbox, in sync with the website.
- **`:Critique since`** shows only what changed since your last review: since the commit your last
  GitHub review was on, or since your last `:Critique submit` in a local review. Opening a PR says when
  it has new commits since your review.
- **`:Critique overview`** shows the PR's branches, review status, checks (failing ones listed),
  description, and conversation. In a local review, it shows every submit summary.

### Changed

- Outdated GitHub threads now show at their original line, marked outdated, as in local reviews. They
  used to be hidden.
- GitHub threads show their comment count as `(2)`, and threads that start with a suggestion read
  "💡 suggested a change".
- The agent skill explains suggestions: apply the code as written unless you disagree.

### Fixed

- The file list jumped back to its first entry on every refresh, e.g. after each saved comment. It keeps
  your place now.
- List entries pointing into a file's old version (deleted files, comments on removed lines) moved down
  by that file's length when it loaded.
- `:Critique files` showed another quickfix list (from `:grep`, say) when that one was in front.

## [0.1.0] - 2026-10-25

First release.

- Review GitHub PRs in a real checkout (a cached blobless clone and one worktree per PR), with a
  GitHub-style diff drawn over the files: green additions, red deleted lines, word highlights, and
  tinted line numbers where you can comment.
- Comments sync to a pending GitHub review as you save them. Reply, edit, delete, resolve, and comment
  on several lines or on deleted lines (`:Critique before`). Submit as Comment, Approve, or Request
  changes.
- Open any PR link, including links to a file, line, or comment. `:Critique link` copies a permalink.
  GitHub Enterprise works through `gh`.
- Local reviews with AI agents: a turn-based review loop through the `critique` CLI and a skill for
  Claude Code, Codex, Cursor, and other agents. Threads follow their code as the agent edits it.
- Live reviews: the agent picks up each comment as you save it.
- `:help critique`, `:Critique help`, and `critique -h`.

[0.2.2]: https://github.com/BSchrift/critique.nvim/compare/v0.2.1...v0.2.2
[0.2.1]: https://github.com/BSchrift/critique.nvim/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/BSchrift/critique.nvim/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/BSchrift/critique.nvim/releases/tag/v0.1.0
