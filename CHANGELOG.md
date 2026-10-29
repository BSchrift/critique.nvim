# Changelog

All notable changes to critique.nvim. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and versions follow [Semantic Versioning](https://semver.org/). Releases are git tags (`v0.2.0`); with
lazy.nvim, `version = '*'` follows them.

## [Unreleased]

## [0.8.0] - 2026-10-28

### Added

- `:checkhealth critique` shows the installed version, and says to restart Neovim when critique was
  updated after this Neovim loaded it (the old version keeps running until then).

### Changed

- The footer on GitHub comments reads "Made with critique.nvim" with the logo as the c, all one link.
  If the image is blocked, its alt text is the c. It stays on by default; `footer = false` turns it off.

### Fixed

- `:checkhealth critique` failed with "attempt to index field 'defaults'" when an older critique was
  still loaded in Neovim.

## [0.7.0] - 2026-10-28

### Added

- A Claude Code plugin: `/plugin install critique --marketplace BSchrift/critique.nvim` installs the
  skill in one step, and keeps it up to date. `:checkhealth critique` finds it.
- A "How it compares" section in the README.

### Fixed

- Security: a review log committed to a repo was treated as yours, so its "human" comments could give an
  agent instructions, and a thread on `../../somewhere` made critique read files outside the checkout.
  Committed review logs are now ignored (critique's own are never committed), and threads on paths
  outside the checkout are dropped.
- A comment window saved into whichever review was open at `:w`, even another PR. It now refuses, and
  keeps your text, if its review isn't the open one.
- A local review write that failed (a full disk, say) was reported as saved. It's an error now.

## [0.6.0] - 2026-10-28

### Added

- A logo: at the top of the README (in light and dark versions), in `assets/`, and as the repo's
  social preview image.

### Changed

- The README shows each feature with a short clip next to it (suggesting by editing, opening a PR,
  coming back to a review), keeping the two long demos for the full flows.
- The footer on GitHub comments shows the logo, small, before "Made with critique.nvim". Footers from
  earlier versions are still hidden in Neovim.

## [0.5.0] - 2026-10-28

### Added

- `:checkhealth critique`: checks Neovim, git, the gh login, the `critique` command, and the agent skill,
  and flags option names that `setup()` doesn't know.
- Tests run on GitHub Actions for every push and pull request: Linux and macOS, with Neovim 0.11, the
  current release, and nightly. A badge in the README shows the result.
- Issue templates (bug reports ask for `:checkhealth critique`), a pull request template, and
  CONTRIBUTING.md.
- Install instructions for Neovim 0.12's `vim.pack`.
- A workflow that publishes each release to LuaRocks, once a `LUAROCKS_API_KEY` secret is set.

### Changed

- `:Critique` with no subcommand comments on the cursor line (or selection) while a review is open, and
  opens the help otherwise. It used to open the local review in the current folder.
- The README describes the product as it is, without a "New in" section.

### Fixed

- `:wq` in a comment on a GitHub PR saved the comment but left it open, since it closed before GitHub
  answered. It now waits for the save (usually under a second), and keeps the comment open if the
  save fails.
- A bare `:Critique` during a GitHub review replaced it with a local review of the PR's checkout (or of
  another PR's), after which `:Critique comment` said your file wasn't in the review. `:Critique open`
  with no argument now refuses inside critique's own PR checkouts.

## [0.4.0] - 2026-10-28

### Added

- A progress line while a PR opens, animated, with git's own progress for each step: "downloading the
  files · Receiving objects: 74% (2892/3907), 5.89 MiB | 11.76 MiB/s", then "checking out the files".
- The tagline, "Explore the code while you review it.", under the README's title.

### Changed

- Opening a PR downloads only what the review needs: the PR's head and merge base without the repo's
  history, and file contents as they're used. On neovim/neovim, a first open fell from about 15 seconds
  and 70 MB to about 8 seconds and 15 MB, most of it the files themselves. Repos cloned by
  earlier versions keep working, history included.
- critique asks GitHub for the PR and fetches its head at the same time, and looks up the merge base
  while the files download.
- PR checkouts made from now on have no history, so `git log` and blame there stop at the PR's head.
- The README's GitHub demo is re-recorded from an empty cache, so it opens with the new download.

## [0.3.0] - 2026-10-28

### Added

- Comments, suggestions, and review summaries posted to GitHub end with a small "Made with
  [critique.nvim](https://github.com/BSchrift/critique.nvim)" link. critique hides it when it shows
  comments, so editing one never adds a second. Turn it off with `footer = false`.
- The agent skill ends commits of work reviewed in critique with a
  `Developed-with: critique (https://github.com/BSchrift/critique.nvim)` trailer, unless you or the
  repo's instructions say not to add trailers.

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

[0.8.0]: https://github.com/BSchrift/critique.nvim/compare/v0.7.0...v0.8.0
[0.7.0]: https://github.com/BSchrift/critique.nvim/compare/v0.6.0...v0.7.0
[0.6.0]: https://github.com/BSchrift/critique.nvim/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/BSchrift/critique.nvim/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/BSchrift/critique.nvim/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/BSchrift/critique.nvim/compare/v0.2.2...v0.3.0
[0.2.2]: https://github.com/BSchrift/critique.nvim/compare/v0.2.1...v0.2.2
[0.2.1]: https://github.com/BSchrift/critique.nvim/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/BSchrift/critique.nvim/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/BSchrift/critique.nvim/releases/tag/v0.1.0
