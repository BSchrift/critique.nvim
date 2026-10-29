-- GitHub PR reviews: the PR's checkout, its threads and viewed marks, and everything posted back. init.lua draws them.
local gh = require('critique.gh')
local diff = require('critique.diff')

local M = {}

-- "Made with critique.nvim", with the logo as the c. Its alt text is the c, so a blocked image still reads right.
local FOOTER = '\n\n<sub>Made with <a href="https://github.com/BSchrift/critique.nvim"><img src="'
  .. 'https://raw.githubusercontent.com/BSchrift/critique.nvim/main/assets/icon-512.png" height="14" align="texttop" '
  .. 'alt="c">ritique.nvim</a></sub>'
-- A GitHub comment as you post it, with the footer (config.footer)...
local function signed(body) return require('critique').config.footer and body .. FOOTER or body end
-- ...and as critique shows it, without (anyone's, any version's), so editing never stacks a second one.
local function unsigned(body) return (body:gsub('%s*<sub>[^\n]*critique%.nvim[^\n]*</sub>%s*$', '')) end

function M.login(c)
  return c.author and c.author.login or 'ghost'
end

-- Files and threads come 100 a page (load asks for the rest).
-- shortcut: 100 comments per thread, and your last review among the last 100; paginate if PRs outgrow that.
local PR_QUERY = [[
query($owner: String!, $name: String!, $number: Int!, $files: String, $reviewThreads: String) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      id title headRefOid baseRefOid
      reviews(states: PENDING, first: 1) { nodes { id } }
      submitted: reviews(last: 100, states: [APPROVED, CHANGES_REQUESTED, COMMENTED, DISMISSED]) { nodes { viewerDidAuthor commit { oid } } }
      files(first: 100, after: $files) { nodes { path viewerViewedState } pageInfo { hasNextPage endCursor } }
      reviewThreads(first: 100, after: $reviewThreads) {
        nodes {
          id isResolved isOutdated path line originalLine diffSide
          comments(first: 100) { nodes { id databaseId body state viewerDidAuthor author { login } } }
        }
        pageInfo { hasNextPage endCursor }
      }
    }
  }
}]]

-- shortcut: the last 100 comments, reviews, and checks.
local OVERVIEW_QUERY = [[
query($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      url body state isDraft reviewDecision baseRefName headRefName author { login }
      commits(last: 1) { nodes { commit { statusCheckRollup { state contexts(last: 100) { nodes {
        ... on CheckRun { name status conclusion }
        ... on StatusContext { context state }
      } } } } } }
      comments(last: 100) { nodes { author { login } body createdAt } }
      reviews(last: 100, states: [APPROVED, CHANGES_REQUESTED, COMMENTED, DISMISSED]) { nodes { author { login } body state submittedAt } }
    }
  }
}]]

local SPINNER = { '⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏' }
-- An animated status line while a PR opens: the step, and git's own progress for it. It stops by itself when the
-- command that started it ends, even with an error.
local progress = {}
function progress.start(step)
  local co, timer, frame = coroutine.running(), vim.uv.new_timer(), 0
  progress.timer, progress.step, progress.detail = timer, step, nil
  timer:start(0, 100, vim.schedule_wrap(function()
    if progress.timer ~= timer or coroutine.status(co) == 'dead' then
      if not timer:is_closing() then timer:close() end
      return
    end
    frame = frame % #SPINNER + 1
    local text = ('%s critique: %s%s'):format(SPINNER[frame], progress.step, progress.detail and (' · ' .. progress.detail) or '')
    vim.api.nvim_echo({ { vim.fn.strcharpart(text, 0, math.max(vim.v.echospace, 20) - 1) } }, false, {})
  end))
end
function progress.set(step) progress.step, progress.detail = step, nil end
function progress.show(detail) progress.detail = detail end
function progress.stop() progress.timer = nil end

-- The PR's threads, viewed marks, and your pending and last reviews, into st (the review's state).
function M.load(st)
  local vars, more, pr = { owner = st.owner, name = st.name, number = st.number }, { files = true, reviewThreads = true }, nil
  while next(more) do -- the next page of each list that has one; a finished list is asked for after its end (empty)
    local page = gh.gql(st.host, PR_QUERY, vars).repository.pullRequest
    pr = pr or vim.tbl_extend('force', page, { files = { nodes = {} }, reviewThreads = { nodes = {} } })
    for key in pairs(more) do
      vim.list_extend(pr[key].nodes, page[key].nodes)
      vars[key] = page[key].pageInfo.endCursor or vars[key]
      more[key] = page[key].pageInfo.hasNextPage or nil
    end
  end
  st.pr_id, st.review_id = pr.id, (pr.reviews.nodes[1] or {}).id
  st.viewed = {}
  for _, f in ipairs(pr.files.nodes) do st.viewed[f.path] = ({ VIEWED = 'viewed', DISMISSED = 'changed' })[f.viewerViewedState] end
  for _, r in ipairs(pr.submitted.nodes) do
    if r.viewerDidAuthor and r.commit then st.reviewed = r.commit.oid end -- your last review's commit, for :Critique since
  end
  st.threads = vim.tbl_map(function(t)
    t.comments, t.outdated = t.comments.nodes, t.isOutdated
    for _, c in ipairs(t.comments) do c.body = unsigned(c.body) end
    t.line = t.line or t.originalLine -- an outdated thread stays where its code was, as in local reviews
    return t
  end, pr.reviewThreads.nodes)
  return pr
end

-- Fetches commits for a PR: just those commits, without their history, in a repo critique set up that way, and
-- as a normal fetch in a full clone (made by critique before 0.4). Returns whether it worked, and git's error.
local function fetch(git_dir, revs, on_progress)
  local args = { 'fetch', '--progress', '--no-tags' }
  if vim.uv.fs_stat(git_dir .. '/critique-shallow') then table.insert(args, '--depth=1') end
  return gh.git_progress(git_dir, on_progress or function() end, vim.list_extend(args, { 'origin', unpack(revs) }))
end

-- Downloads the file contents of a commit, with progress. Checking it out would download them anyway, but silently.
-- git skips those it already has.
local function fetch_files(git_dir, rev, on_progress)
  local ids = {}
  for id in gh.git(git_dir, 'ls-tree', '-r', rev):gmatch(' blob (%x+)\t') do ids[#ids + 1] = id end
  if #ids == 0 then return true end -- with nothing to ask for, git would fetch every branch
  -- One string: given a list, vim.system writes each id separately, which blocks Neovim for seconds in a monorepo.
  return gh.git_progress(git_dir, on_progress, { 'fetch', '--progress', '--no-tags', '--no-write-fetch-head', '--stdin', 'origin' },
    table.concat(ids, '\n') .. '\n')
end

local function must(ok, err)
  if not ok then error(err, 0) end
end

-- The diff since the commit your last review was on, for :Critique since.
function M.since(st)
  if not st.reviewed then error("you haven't reviewed this PR yet", 0) end
  st.fetched = st.fetched or {} -- once per commit: refresh asks again after every comment
  if not st.fetched[st.reviewed] then
    if not fetch(st.git_dir, { st.reviewed }) then
      error(("can't fetch %s, the commit of your last review; was it force-pushed away?"):format(st.reviewed:sub(1, 7)), 0)
    end
    st.fetched[st.reviewed] = true
  end
  return gh.git(st.git_dir, unpack(vim.list_extend(vim.list_slice(diff.GIT_ARGS), { st.reviewed, st.head })))
end

local function ensure_review(st)
  st.review_id = st.review_id
    or gh.mutate(st.host, 'addPullRequestReview', { pullRequestId = st.pr_id, commitOID = st.head }, 'pullRequestReview { id }').pullRequestReview.id
  return st.review_id
end

-- Saves a comment to your pending review: an edit of ctx.comment, a reply in ctx.thread, or a new thread at ctx.anchor.
function M.post(st, ctx, body)
  if ctx.comment then
    gh.mutate(st.host, 'updatePullRequestReviewComment', { pullRequestReviewCommentId = ctx.comment.id, body = signed(body) })
  elseif ctx.thread then
    local input = { pullRequestReviewThreadId = ctx.thread.id, pullRequestReviewId = ensure_review(st), body = signed(body) }
    ctx.comment = gh.mutate(st.host, 'addPullRequestReviewThreadReply', input, 'comment { id }').comment
  else
    local input = vim.tbl_extend('force', ctx.anchor, { pullRequestReviewId = ensure_review(st), body = signed(body) })
    local t = gh.mutate(st.host, 'addPullRequestReviewThread', input, 'thread { id comments(first: 1) { nodes { id } } }').thread
    if not t then error('GitHub rejected the comment', 0) end
    ctx.comment = t.comments.nodes[1]
  end
end

function M.delete(st, c)
  gh.mutate(st.host, 'deletePullRequestReviewComment', { id = c.id })
end

function M.resolve(st, t)
  gh.mutate(st.host, t.isResolved and 'unresolveReviewThread' or 'resolveReviewThread', { threadId = t.id })
end

-- The PR's own "Viewed" checkbox.
function M.viewed(st, path, on)
  gh.mutate(st.host, on and 'markFileAsViewed' or 'unmarkFileAsViewed', { pullRequestId = st.pr_id, path = path })
end

-- Asks how to submit your pending review (or a review with just a summary), and submits it. Nil if you cancel.
function M.submit(st)
  local event = gh.await(vim.ui.select, { 'COMMENT', 'APPROVE', 'REQUEST_CHANGES' }, {
    prompt = 'Submit review as',
    format_item = function(e) return (e:lower():gsub('_', ' ')) end,
  })
  if not event then return end
  local body = gh.await(vim.ui.input, { prompt = 'Summary (optional): ' })
  if not body then return end
  body = body ~= '' and signed(body) or nil
  if st.review_id then
    gh.mutate(st.host, 'submitPullRequestReview', { pullRequestReviewId = st.review_id, event = event, body = body })
  else
    gh.mutate(st.host, 'addPullRequestReview', { pullRequestId = st.pr_id, commitOID = st.head, event = event, body = body })
  end
  return 'review submitted'
end

local FAILED = { failure = true, error = true, timed_out = true, cancelled = true, startup_failure = true, action_required = true }

-- For :Critique overview: the PR's branches, review status, checks, and description (as lines), and its conversation.
function M.overview(st)
  local pr = gh.gql(st.host, OVERVIEW_QUERY, { owner = st.owner, name = st.name, number = st.number }).repository.pullRequest
  local checks = vim.tbl_get(pr, 'commits', 'nodes', 1, 'commit', 'statusCheckRollup')
  local lines, entries = {
    ('%s wants to merge `%s` into `%s` · %s%s'):format(M.login(pr), pr.headRefName, pr.baseRefName, pr.state:lower(), pr.isDraft and ' · draft' or ''),
    pr.url, '',
  }, {}
  if pr.reviewDecision then table.insert(lines, 'Review: ' .. pr.reviewDecision:lower():gsub('_', ' ')) end
  local passed, skipped, rest = 0, 0, {} -- like GitHub: count what passed, list the rest
  for _, c in ipairs(checks and checks.contexts.nodes or {}) do
    local result = (c.conclusion or c.state or c.status):lower()
    if result == 'success' then passed = passed + 1
    elseif result == 'skipped' or result == 'neutral' then skipped = skipped + 1
    else table.insert(rest, ('- %s %s (%s)'):format(FAILED[result] and '✗' or '•', c.name or c.context, (result:gsub('_', ' ')))) end
  end
  table.insert(lines, checks and ('Checks: %s · %d passed%s'):format(checks.state:lower(), passed, skipped > 0 and (', ' .. skipped .. ' skipped') or '')
    or 'Checks: none')
  vim.list_extend(lines, rest)
  vim.list_extend(lines, { '', '## Description', '' })
  vim.list_extend(lines, pr.body ~= '' and vim.split((pr.body:gsub('\r', '')), '\n') or { '_No description._' })
  for _, c in ipairs(pr.comments.nodes) do table.insert(entries, { who = M.login(c), at = c.createdAt, body = unsigned(c.body) }) end
  for _, r in ipairs(pr.reviews.nodes) do
    local body = unsigned(r.body)
    if body ~= '' or r.state ~= 'COMMENTED' then -- a bare COMMENTED review is just its threads, which are on the code
      local verdict = ({ APPROVED = ' approved', CHANGES_REQUESTED = ' requested changes', DISMISSED = ' (dismissed)' })[r.state] or ''
      table.insert(entries, { who = M.login(r) .. verdict, at = r.submittedAt, body = body })
    end
  end
  table.sort(entries, function(a, b) return a.at < b.at end)
  return lines, entries
end

-- Permalink to lines of a file at the commit a side shows (LEFT: the merge base).
function M.permalink(st, path, side, line1, line2)
  local file = st.by_path[path]
  if side == 'LEFT' and file then path = file.old_path end
  local lines = line1 == line2 and ('L%d'):format(line1) or ('L%d-L%d'):format(line1, line2)
  return ('https://%s/%s/%s/blob/%s/%s#%s'):format(st.host, st.owner, st.name, side == 'LEFT' and st.base or st.head,
    (path:gsub('[^%w%-._~/]', function(c) return ('%%%02X'):format(c:byte()) end)), lines)
end

-- Where your edits in a PR's checkout went when they were in the way of its new commits.
local function stash_note(files, wt)
  return ("your edits to %s in the PR's checkout were in the way of its new commits, so they're stashed. "
    .. 'To get them back: git -C %s stash pop'):format(#files <= 3 and table.concat(files, ', ') or (#files .. ' files'),
    vim.fn.shellescape(wt))
end

-- Gets a PR ready to review, with a progress line: its checkout in critique's cache (made or brought up to date),
-- threads, and diff. Returns the review's state; st.stashed says where edits in the way went.
function M.open(host, owner, name, number)
  local st = { host = host, owner = owner, name = name, number = number, overlay = true, by_path = {}, backend = M }
  progress.start(('opening %s/%s#%s'):format(owner, name, number))
  local root = ('%s/critique/%s/%s/%s'):format(vim.fn.stdpath('cache'), host, owner, name)
  local git_dir, wt = root .. '/repo.git', root .. '/pr-' .. number
  if not vim.uv.fs_stat(git_dir) then
    -- A repo of just the commits reviews need, without their history, and file contents only once they're used.
    -- gh supplies the credentials for private repos. Set up under another name, so a half-made one is never used.
    local new = git_dir .. '.new'
    vim.fn.mkdir(root, 'p')
    vim.fn.delete(new, 'rf')
    gh.git(root, 'init', '--quiet', '--bare', new)
    gh.git(new, 'remote', 'add', 'origin', ('https://%s/%s/%s.git'):format(host, owner, name))
    for _, kv in ipairs({ { 'remote.origin.promisor', 'true' }, { 'remote.origin.partialclonefilter', 'blob:none' },
      { 'credential.helper', '' }, { 'credential.helper', '!gh auth git-credential' } }) do
      gh.git(new, 'config', '--add', kv[1], kv[2])
    end
    vim.fn.writefile({}, new .. '/critique-shallow')
    assert(vim.uv.fs_rename(new, git_dir))
  end
  -- The PR from GitHub's API, and meanwhile its head commit.
  local pr = gh.all({
    function() return M.load(st) end,
    function() must(fetch(git_dir, { ('refs/pull/%d/head'):format(number) }, progress.show)) end,
  })
  -- Never ask git whether it has a commit (cat-file -e): in a partial clone, a missing one is then downloaded with
  -- its whole history. Compare with what was fetched, or just fetch: git skips commits it already has.
  if vim.trim(gh.git(git_dir, 'rev-parse', 'FETCH_HEAD')) ~= pr.headRefOid then
    must(fetch(git_dir, { pr.headRefOid }, progress.show)) -- pushed to a moment ago
  end
  -- The files, and meanwhile the merge base that GitHub diffs against (git fetches run one at a time: they lock).
  progress.set('downloading the files')
  local fresh = not vim.uv.fs_stat(wt)
  st.base = gh.all({
    function() return gh.merge_base(host, owner, name, pr.baseRefOid, pr.headRefOid) end,
    function()
      if fresh then
        gh.git(git_dir, 'worktree', 'prune') -- forget a checkout folder you deleted, or git won't make it again
        gh.git(git_dir, 'worktree', 'add', '--quiet', '--no-checkout', '--detach', wt, pr.headRefOid)
      end
      must(fetch_files(git_dir, pr.headRefOid, progress.show))
      progress.set('checking out the files')
      local ok, err = gh.git_progress(wt, progress.show, { 'checkout', '--progress', '--detach', pr.headRefOid })
      local edited = not ok and not fresh and vim.tbl_map(function(l) return l:sub(4) end, -- "XY path"
        vim.split(gh.git(wt, 'status', '--porcelain', '--untracked-files=all'), '\n', { trimempty = true }))
      if edited and #edited > 0 then
        -- Edits in the checkout are in the way of the new commits (saved with auto_suggest off, by an auto-save
        -- plugin, or by critique before 0.2). Stash them, new files too, so nothing is lost, and try again.
        gh.git(wt, 'stash', 'push', '--include-untracked', '-m', ('critique: your edits, set aside to reopen PR #%d'):format(number))
        st.stashed = stash_note(edited, wt)
        ok, err = gh.git_progress(wt, progress.show, { 'checkout', '--progress', '--detach', pr.headRefOid })
        if not ok then err = err .. '\n' .. st.stashed end
      end
      must(ok, err)
    end,
  })
  must(fetch(git_dir, { st.base }))

  progress.set('computing the diff')
  st.git_dir, st.dir, st.head = git_dir, vim.uv.fs_realpath(wt), pr.headRefOid
  st.files = diff.parse(gh.git(git_dir, unpack(vim.list_extend(vim.list_slice(diff.GIT_ARGS), { st.base, st.head }))))
  for _, f in ipairs(st.files) do st.by_path[f.path] = f end
  st.title = ('#%d %s'):format(number, pr.title)
  progress.stop()
  return st
end

return M
