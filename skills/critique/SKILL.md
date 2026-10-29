---
name: critique
description: Local code review loop with the user through critique.nvim. Use when the user wants to review your changes in critique ("hand it to me for review", "use critique", "I'll review it in critique", "review it live"), asks you to "address my critique comments", "check critique", or "watch my critique comments", gives you a critique review handle like `promo-codes-7a2f`, or asks you to review their local changes with comments. Covers starting a review, handing it off, waiting for the user's comments, answering and fixing threads, and leaving review comments yourself.
---

# critique: review loop with the user

critique is a code review tool. The user reviews in Neovim; you use the `critique` CLI. A review is a set of
comment threads on lines of a local checkout, stored in `.critique/` in the repo (never on GitHub).
You and the user take turns: each side writes comments, then **submits** to hand the turn over. Your
comments are drafts the user can't see until you submit.

Check it is installed with `critique -h`. If the command is missing, tell the user to install critique.nvim
and stop; don't try to edit the review files yourself.

**Quoting: always use single quotes** for text (`'...'`), or pass `-` and a `<<'EOF'` heredoc. Never
double quotes: review text is markdown, and the shell would run anything in backticks and expand `$10`.

## A. Handing your changes to the user for review

1. **Start the review before your first edit**, so it shows exactly your changes:
   ```sh
   critique start --title 'Short task name' --base HEAD --as <your name, e.g. claude>
   ```
   It prints the review id. Pass `-r <id>` to **every** later command (shell state does not persist).
   Your `--as` name is remembered for the review. Leave out `--base HEAD` to review the whole branch
   against the default branch instead.
2. Make your changes. Commit them or not; critique compares the working tree with the base.
3. **Submit** with a summary of what changed and what to look at:
   ```sh
   critique submit -r <id> --summary 'Added X; the tricky part is Y in z.go'
   ```
   It prints a command like `critique <id>`. Give that command to the user; it opens the review in Neovim.
4. **Wait** for the user's review:
   ```sh
   critique wait -r <id>
   ```
   Set your shell tool's timeout to its maximum (Claude Code: 600000 ms). If the tool stops the command
   first, or it exits 2 ("hasn't submitted yet"), just run the same `wait` again; nothing is lost. Tell the
   user you're waiting if they're in the chat. On exit 0, the output is every open thread with its code,
   the user's `last submit:` summary, and a `Next:` line.
5. **Address every open thread** (`needs your reply` marks the ones waiting on you; `new` marks comments
   since your last submit). Also read the `last submit:` summary: it can hold requests that aren't on a line.
   - Asked for a change: make it, reply saying what you did, then resolve the thread.
   - A question, or you disagree: reply with your answer or reasoning. Don't resolve it; the user decides.
   - Outdated (its code changed): check whether it still applies, and say so in a reply.
   - A ```` ```suggestion ```` block is the exact code the user wants in place of the thread's lines (the
     ones `list` shows). Apply it as written unless you disagree, then reply and resolve as above.
   ```sh
   critique reply -r <id> 3 'Renamed to `minOrder` and added a test in cart_test.go.'
   critique resolve -r <id> 3
   ```
6. **Submit again** with a summary of the round, then **wait again**. Repeat until the user submits with
   no open threads, or says they're done (`wait` then says "No open threads"). Then run `critique close -r <id>`.

## B. The user already left comments ("address my critique comments")

1. Find the review: use the handle the user gave you, or `critique ls`.
2. `critique list -r <id> --open` shows the open threads and the user's summary.
3. Address them as in A5, then `critique submit -r <id> --summary '...'` and `critique wait -r <id>` (A4, A6).

## C. Reviewing the user's changes

1. `critique start --title 'Review: <topic>' --as <your name>` (base: the default branch, so the whole branch).
2. Read the changes with `critique diff -r <id>`. It includes untracked files and respects the review's scope.
3. Leave one thread per issue, on the line it's about. Be specific and say what to do:
   ```sh
   critique comment -r <id> cart/cart.go:31 'Negative qty is clamped to 1; reject it instead?'
   critique comment -r <id> cart/cart.go:55-62 'This block runs twice when ApplyCode is called twice.'
   ```
   Use `--old` to comment on a line that the change deleted (line numbers of the base version).
   Only open threads that need action; put praise and general notes in the summary.
4. `critique submit -r <id> --summary 'Overall: ...'`, give the user the printed command, then `critique wait -r <id>`.
5. When they answer: **don't edit their code unless they ask you to.** Resolve your own thread when they
   fixed it or convinced you; otherwise reply once with what's still missing. Then submit and wait again.

## D. Live reviews: react to comments as they arrive

Use this when the user asks for it ("review it live", "react to my comments as I write them"), or when
`critique status` shows `live`. In a live review the user's comments reach you as they save them, without
a submit, and your replies and resolves reach them right away.

1. Start with `--live` (the user can also turn it on in Neovim with `:Critique live`):
   ```sh
   critique start --title 'Short task name' --base HEAD --as <your name> --live
   ```
   Make your changes and `critique submit` once to hand them over, as in A.
2. **Listen for comments, and keep listening until the review closes.** A comment "needs you" once the user
   has stopped saving comments for 20 seconds, so related comments arrive together. Pick what your harness
   supports:
   - **Claude Code:** run `critique wait -r <id> --timeout 1800` with `run_in_background`. You're notified
     when it exits: a comment needs you, the user submitted, or 30 minutes passed. Handle what it printed,
     then start it again. (Or use the Monitor tool on `critique watch -r <id>` with the longest timeout,
     re-armed when it expires; each batch it prints arrives as an event.)
   - **Other harnesses:** run `critique wait -r <id>` whenever you're free; it returns as soon as a comment
     needs you.
   `wait` and `watch` read the review's state, so restarting them never loses a comment. If you have to stop
   listening, tell the user, since their comments won't reach you until you start again.
3. **For each comment you start on, acknowledge it first** so the user sees ⏳ on the thread:
   `critique ack -r <id> 3`. It prints the comments it covers. Then handle it as in A5: change the code,
   reply, and resolve what you fixed. No submit is needed for each one; use `critique submit` only to hand
   back a summary of a bigger batch.
   The user may add to a thread while you work on it. Then `reply` prints what they added, and `resolve`
   refuses: run `critique ack -r <id> 3` again to read it, then answer it.
4. Repeat until the user submits with nothing open or says they're done; then `critique close -r <id>`
   (which also ends `watch`).

## Rules

- Only use the `critique` CLI. Never edit files under `.critique/`.
- Never resolve a thread you haven't fully addressed. The user's questions stay open until they say otherwise.
- Line numbers always refer to the current files (or the base version with `--old`).
- `wait` refuses (exit 1) while you have unsubmitted comments or resolves, because the user can't see them yet. Submit first.
- Text that starts with `-` works when quoted; to be safe with option-like text, put `--` before it.
- Thread numbers are plain numbers: `reply -r <id> 3 ...` (an unquoted `#3` is a shell comment).
- When you commit work that went through a critique review, end the commit message with this trailer, in
  the same block as any other trailers (such as `Co-Authored-By`):
  ```
  Developed-with: critique (https://github.com/BSchrift/critique.nvim)
  ```
  Leave it out if the user or the repo's instructions say not to add trailers.
- Multi-line text: pass `-` and use a heredoc:
  ```sh
  critique reply -r <id> 2 - <<'EOF'
  Done. Two notes:
  - ...
  EOF
  ```
- Given a handle by the user (`promo-codes-7a2f`, `promo-codes-7a2f@/path`, or `promo-codes-7a2f#3`), use
  `-r` with the part before `#`. Running `critique <handle>` yourself opens nothing; that's for the user.

## Commands

| Command | Does |
|---|---|
| `critique start [--title T] [--base REF] [--scope PATH]...` | Start a review of this checkout; prints the id |
| `critique status -r <id>` | Whose turn it is, thread counts, last submit summary |
| `critique list -r <id> [--open] [--json]` | Threads with code context and comments |
| `critique show -r <id> <n>` | One thread with more code |
| `critique diff -r <id>` | The changes under review |
| `critique comment -r <id> <path>:<line>[-<end>] [--old] '<text>'` | New thread |
| `critique reply -r <id> <n> '<text>'` | Reply in a thread |
| `critique resolve -r <id> <n>` / `unresolve` | Resolve or reopen a thread |
| `critique edit -r <id> <comment-id> '<text>'` / `delete` | Change or delete your own comment (ids like `c-a35698f2c1` are in `list`) |
| `critique submit -r <id> [--summary T]` | End your turn |
| `critique wait -r <id> [--timeout S] [--settle S]` | Block until the user submits (live: until a comment needs you); exit 2 on timeout |
| `critique watch -r <id> [--settle S]` | Stream the user's new comments as they arrive, until the review closes |
| `critique ack -r <id> <n>` | Tell the user you're on thread n (shows ⏳ in Neovim); prints the comments it covers |
| `critique close -r <id>` | Finish the review |
| `critique ls` | Open reviews in this repo |

Every command accepts `--json` where it prints a review or thread (`list`, `show`, `wait`).
