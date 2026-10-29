# Contributing

Thanks for helping. Issues and pull requests are welcome; for a bigger change, open an issue or a
discussion first so we can agree on the approach. Working with an AI agent? Point it at
[AGENTS.md](AGENTS.md).

## Running the tests

```sh
tests/run.sh               # every test: unit tests, plus the CLI and Neovim UI against temp git repos
tests/run.sh cli local     # just some of them
```

They run offline in headless Neovim (0.11 or newer) and need only git. GitHub is stubbed out:
`tests/github_test.lua` stands a local repo in for GitHub. CI runs them on Linux and macOS, on Neovim
0.11, the current release, and nightly.

## Where things are

| File | What it does |
|---|---|
| `lua/critique/init.lua` | The `:Critique` commands and everything you see in Neovim |
| `lua/critique/diff.lua` | Parsing `git diff` and drawing the diff overlay |
| `lua/critique/store.lua` | Local reviews: the event log in `.critique/` |
| `lua/critique/cli.lua` | The `critique` shell command that agents use |
| `lua/critique/gh.lua` | Async helpers, git, and GitHub's API through `gh` |
| `lua/critique/health.lua` | `:checkhealth critique` |
| `skills/critique/SKILL.md` | The skill that teaches agents the review loop |

## Releasing

1. Move "Unreleased" in `CHANGELOG.md` to the new version, with the date.
2. Set the same version in `.claude-plugin/plugin.json`, so Claude Code sees the update.
3. Commit, wait for CI to pass, then tag `vX.Y.Z` and create the GitHub release from the changelog section.

## Style

- Match the code around your change: its naming, its idioms, and its short comments that say why,
  not what.
- Every user-visible change gets a test, a line in `CHANGELOG.md` under "Unreleased", and docs in the
  README and `doc/critique.txt`.
- Messages to the user are plain sentences that say what happened and what to do next.
