# critique.nvim

Review GitHub pull requests in Neovim, inside a real checkout of the PR.

![critique.nvim demo](demo/demo.gif)

<sub>Demo in full quality: [demo/demo.mp4](demo/demo.mp4)</sub>

- **GitHub-style diff over the real files.** Added lines are green, removed lines appear as red
  virtual lines, and changed words are highlighted, using the same hunks as GitHub's Files tab.
  Line numbers you can comment on are tinted gray-blue.
- **Everything else keeps working.** It's a normal checkout, so your LSP, telescope, `gd`,
  grep, and formatters all work as usual, in PR files and in the rest of the repo.
- **Comments sync as you write them.** Each `:w` saves a comment to your pending review on GitHub.
  `:Critique submit` publishes them all at once as Comment, Approve, or Request changes.
- **Full review workflow.** You can read and reply to other reviewers' threads, resolve
  threads, delete your own comments, comment on several lines at once, and comment on deleted lines.
- **Before/after.** Switch any file to its pre-PR version at the same spot, or hide the diff
  overlay for a plain view.
- **Share a line.** `:Critique link` copies a permalink to the line you're on.
- **GitHub Enterprise.** Works with self-hosted GitHub. critique takes the host from the PR URL.

## Getting started

### 1. Requirements

- Neovim **0.11+**
- `git`
- [GitHub CLI](https://cli.github.com) (`brew install gh`), logged in:

  ```sh
  gh auth login
  ```

  critique uses gh for everything: fetching the PR, cloning private repos, and posting comments.
  It doesn't need its own token.

  For **GitHub Enterprise Server**, log in to your company's host once:
  `gh auth login --hostname github.yourcompany.com`. The `critique` launcher prompts you
  to do this the first time you open a PR from a new host.

### 2. Install the plugin

[lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{ 'BSchrift/critique.nvim' }
```

There's no need to lazy-load it: at startup it only defines the `:Critique` command, which adds
a few hundredths of a millisecond. Lazy-loading would also hide `:help critique` until the first `:Critique`.

Other plugin managers work the same way: add `BSchrift/critique.nvim`. There's no `setup()` call
and nothing to configure.

### 3. Add the `critique` launcher (optional)

This lets you start a review from your shell. It links the launcher into a directory on your `PATH`:

```sh
ln -s ~/.local/share/nvim/lazy/critique.nvim/bin/critique ~/.local/bin/critique
```

(Adjust the first path if your plugin manager installs somewhere else.)

### 4. Review your first PR

```sh
critique https://github.com/owner/repo/pull/123
```

Or, from inside Neovim: `:Critique open https://github.com/owner/repo/pull/123`.

You can paste any PR link, including links copied from GitHub that point at a specific file,
line, or comment (`…/pull/123/changes#diff-…R31`, `…/pull/123#discussion_r…`).
critique opens the PR and jumps to that spot.

The first time you open a repo, critique clones it, which takes a few seconds. Later opens only
fetch new commits. Then:

1. **Find your way around.** The changed files are in the quickfix list (`:cnext` / `:cprev`), and
   `]c` / `[c` jump between changes in a file. You can open any other file with your usual tools.
2. **Comment.** Put the cursor on a line and run `:Critique comment`. A markdown buffer opens.
   Write below the `▼` line, then `:w` to save the comment to your pending review and `:q` to close.
   For a multi-line comment, select the lines in visual mode first.
3. **Reply or edit.** Run `:Critique comment` on a line that already has a thread. You'll see
   the whole thread and can reply, or edit your pending comment.
4. **Look back.** `:Critique before` shows the file as it was before the PR (comment there to
   comment on deleted lines). `:Critique after` comes back.
5. **Share a line.** `:Critique link` copies a permalink to the cursor line (or a visual
   selection) to your clipboard, ready to paste into Slack or a ticket.
6. **Submit.** `:Critique submit` asks for Comment / Approve / Request changes and an optional summary.

Until you submit, your comments are a pending review: they're saved on GitHub but only you can see them.
If you quit halfway, run `critique <url>` again and continue where you left off.

### 5. Add keymaps (recommended)

critique doesn't set any keymaps other than `]c` / `[c` in changed files. Some suggestions:

```lua
vim.keymap.set({ 'n', 'x' }, '<leader>cc', ':Critique comment<cr>', { desc = 'Critique: comment' })
vim.keymap.set('n', '<leader>cb', function()
  vim.cmd.Critique(vim.api.nvim_buf_get_name(0):match('^critique://') and 'after' or 'before')
end, { desc = 'Critique: before/after' })
vim.keymap.set('n', '<leader>ct', '<cmd>Critique toggle<cr>', { desc = 'Critique: toggle diff' })
vim.keymap.set({ 'n', 'x' }, '<leader>cl', ':Critique link<cr>', { desc = 'Critique: copy link to line' })
vim.keymap.set('n', '<leader>cr', '<cmd>Critique resolve<cr>', { desc = 'Critique: resolve thread' })
vim.keymap.set('n', '<leader>cs', '<cmd>Critique submit<cr>', { desc = 'Critique: submit review' })
```

## Commands

| Command | What it does |
|---|---|
| `:Critique open <url>` | Fetch the PR, check it out, show the diff. If the URL links to a file, line, or comment, jump there |
| `:Critique comment` | Comment on the cursor line, or open the thread already there |
| `:'<,'>Critique comment` | Multi-line comment on a visual selection (always starts a new thread) |
| `:Critique delete` | Delete one of your comments on the cursor line |
| `:Critique resolve` | Resolve / unresolve the thread on the cursor line |
| `:Critique before` | Show the file as it was before the PR, at the matching line |
| `:Critique after` | Back to the PR's version of the file |
| `:Critique toggle` | Hide / show the diff overlay |
| `:Critique link` | Copy a permalink to the cursor line (or a visual selection's lines) |
| `:Critique files` | Reopen the changed-files list |
| `:Critique refresh` | Reload comments from GitHub |
| `:Critique submit` | Publish your pending review |
| `:Critique help` | Open the help (`:help critique`) |

As on GitHub, you can comment only on lines inside a diff hunk: changed lines plus 3 lines
of context around them. Their line numbers are tinted gray-blue.

Full documentation is in Neovim: `:help critique` (or `:Critique help`). For the shell launcher's
options, run `critique -h`.

`:Critique link` builds a `https://<host>/<owner>/<repo>/blob/<commit>/<path>#L<n>` permalink.
The host comes from the PR URL, so self-hosted GitHub works without any setup. The link points
at the commit you're looking at: the PR head, or in `:Critique before`, the base commit (and the
file's old path if it was renamed). It works for any file in the repo, not just files in the PR.
The link goes to your system clipboard (`+`) and the unnamed register. If Neovim has no
clipboard provider, it goes to the unnamed register only, so `p` pastes it.

## How it works

- Each repo is cloned once, blobless, to `~/.cache/nvim/critique/<host>/<owner>/<repo>/repo.git`.
  Each PR gets a git worktree next to it, at `.../pr-<number>`. Neovim's working directory
  is set to that worktree, which is why every other tool just works.
- Reopening a PR fetches new commits and checks out the PR head. If you've edited files in the
  worktree, the checkout refuses instead of overwriting them.
- The diff is `git diff <merge-base> <head>` with GitHub's settings: 3 context lines, rename
  detection, Myers algorithm. Your git config can't change the hunks.
- Removed lines are drawn as virtual lines, so the buffer is always the real file on disk.
- Comments go through GitHub's GraphQL API via `gh api graphql`.

## Troubleshooting

| Problem | Fix |
|---|---|
| `To get started with GitHub CLI, please run: gh auth login` | Run `gh auth login`. The `critique` launcher offers to do this for you. |
| `GitHub only accepts comments on lines inside one diff hunk` | Comment on a changed line or within 3 lines of one. For deleted lines, use `:Critique before`. |
| `save or undo your edits first` | Comments are placed by line number, so the buffer must match the PR. Undo (`u`) or `:e!`. |
| Reopening fails with a checkout error | You changed files in the worktree. Go to `~/.cache/nvim/critique/<host>/<owner>/<repo>/pr-<n>` and `git stash` or `git checkout .`. |
| LSP errors about missing dependencies | The worktree is a fresh checkout. Install the project's dependencies there as you would for any clone. |
| A thread I expect isn't shown | Outdated threads (on code that has since changed) are hidden, as on GitHub's Files tab. |
| `HTTP 401` or `authentication required` for a company host | Run `gh auth login --hostname <your GitHub host>`. |
| `:Critique link` says "no system clipboard" | Neovim found no clipboard tool. The link is in the unnamed register (`p` pastes it). See `:help clipboard`. |
| Using too much disk | Delete `~/.cache/nvim/critique` (or one `<host>/<owner>/<repo>` inside it). |

## Customizing colors

The defaults use GitHub's diff colors and pick the light or dark set based on `background`.
To override them, define these highlight groups in your config:

`CritiqueAdd`, `CritiqueAddWord`, `CritiqueAddSign`, `CritiqueDelete`, `CritiqueDeleteWord`,
`CritiqueDeleteSign`, `CritiqueHunk` (tinted line numbers), `CritiqueThread`, `CritiquePending`,
`CritiqueResolved`

## Limits

- Loads up to 100 review threads per PR, and up to 100 comments per thread.
- Assumes one review is open at a time per Neovim instance.

## Development

```sh
nvim --headless -l tests/diff_test.lua   # diff parser and rendering tests
vhs demo/demo.tape                       # re-record the demo (needs vhs; edit the PR URL first)
```

## License

MIT, see [LICENSE](LICENSE).
