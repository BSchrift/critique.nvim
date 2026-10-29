# Working on critique.nvim

Instructions for AI agents (and people) changing this repo. CONTRIBUTING.md has the file layout and the
release steps; this file adds what an agent needs to work here safely.

## Work like ponytail

Use the [ponytail](https://github.com/DietrichGebert/ponytail) skill for all work here: the smallest
change that fully solves the task, reusing what the code already has, with a test for any new logic,
and a reply that ends with what you skipped and any risk.

- **Claude Code:** this repo's `.claude/settings.json` adds ponytail's marketplace and turns the plugin
  on once you trust the folder. If Claude Code says it isn't installed, run `/plugin install ponytail@ponytail`.
  (Claude Code reads this file through `CLAUDE.md`.)
- **Codex:** `codex plugin marketplace add DietrichGebert/ponytail`, then `codex plugin add ponytail@ponytail`.
- **Other agents:** follow ponytail's [AGENTS.md](https://github.com/DietrichGebert/ponytail/blob/main/AGENTS.md).

## Before you change code

- Read the code the change touches, and grep every caller. `lua/critique/init.lua` draws both GitHub
  reviews and local (agent) reviews, through `S.backend`: `github.lua` or `local.lua`, which offer the
  same functions. A change to one backend usually needs the same change in the other.
- Supported: Neovim 0.11 and newer. Use 0.12-only APIs only with a fallback (see `M.text` in diff.lua).
- Async code runs in coroutines (`gh.async` / `gh.await` / `gh.all` / `gh.wait` in `lua/critique/gh.lua`).
  Never wrap a call that can yield in `pcall`: it fails on PUC Lua builds of Neovim.
- critique's PR checkouts are partial, history-free clones. Never run git commands there that look up
  objects that may be missing (`cat-file -e`, `rev-parse <sha>^{commit}`): git then downloads the
  commit with its whole history. Fetch with `--depth=1` instead, as `fetch()` in github.lua does.

## Tests

- `tests/run.sh` runs everything, offline, in a few minutes; `tests/run.sh local github` runs some.
  GitHub is stubbed: `tests/github_test.lua` uses local repos as the "GitHub" remote.
- Every behavior change gets a test that fails without the change. Check it: break the code, run
  the test, see it fail, restore.
- Don't make tests depend on timing or on the machine (tags, the user's config, network). CI runs on
  Linux and macOS with Neovim 0.11.0, stable, and nightly, and checks out without tags.

## Docs

- A change users will notice also updates `README.md`, `doc/critique.txt` (78 columns), and a line
  under "Unreleased" in `CHANGELOG.md`.
- The README describes the product as it is: no "new in" sections or version history; that belongs
  in the changelog.
- `skills/critique/SKILL.md` is product too: users' agents follow it.
- Plain English: short sentences, everyday words, say what to do next.

## Anything outside this checkout needs the user's OK first

- Pushing, tagging, releasing, and any GitHub write (comments, reviews, PRs, deleting anything),
  including on the demo sandbox repo BSchrift/nvim-reviewer-sandbox. Read-only `gh` calls are fine.
- After every push, wait for CI (`gh run watch`) and fix a failure right away, before other work.
- Release only on a green CI run, following CONTRIBUTING.md (the changelog and
  `.claude-plugin/plugin.json` versions must match the tag).
- Don't change the user's own setup (`~/.config/nvim`, `~/.claude`) unless asked.

## Demos

`demo/*.tape` and `demo/clips/*.tape` record the README's GIFs with [vhs](https://github.com/charmbracelet/vhs).
The clips stage a local review with `demo/clips-setup.sh` and need no GitHub writes; `demo/demo.tape`
posts to the sandbox PR, so it needs the user's OK. Look at the frames of every recording before
using it.
