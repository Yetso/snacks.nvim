---@diagnostic disable: missing-fields
local M = {}

---@class snacks.explorer.git.Status
---@field status string
---@field file string

local uv = vim.uv or vim.loop

local CACHE_TTL = 15 * 60 -- 15 minutes

-- Marker printed before the status of each submodule (see `repo_status`)
local SUBMODULE_MARKER = "\001"

-- When the cwd is not inside a git repo, look this many levels deep for repos
local MAX_DEPTH = 3

---@class snacks.explorer.git.State
---@field tick number
---@field last number
---@field repos string[] repositories whose status is shown
---@field scanned? boolean `repos` was filled by `find_repos` (cwd not inside a repo)
---@field rescan? boolean a refresh happened outside the known repos, so repos may have been added/removed

--- Keyed by git root, or by the cwd when it's not inside a git repo
M.state = {} ---@type table<string, snacks.explorer.git.State>

---@param untracked? boolean
local function status_args(untracked)
  return { "status", "--porcelain=v1", "--ignored=matching", "-z", untracked and "-unormal" or "-uno" }
end

--- Runs git in `cwd` and calls `cb` with its stdout (empty when git can't be started).
---@param cwd string
---@param args string[]
---@param cb fun(output: string)
local function git(cwd, args, cb)
  local output = ""
  local stdout = assert(uv.new_pipe())
  local handle ---@type uv.uv_process_t
  handle = uv.spawn("git", {
    stdio = { nil, stdout, nil },
    cwd = cwd,
    hide = true,
    args = vim.list_extend({ "--no-pager", "--no-optional-locks" }, args),
  }, function()
    handle:close()
  end)
  if not handle then
    stdout:close()
    return cb("")
  end
  stdout:read_start(function(err, data)
    assert(not err, err)
    if data then
      output = output .. data
    else
      stdout:close()
      cb(output)
    end
  end)
end

--- Parses `git status --porcelain=v1 -z` output.
--- Entries following a `SUBMODULE_MARKER .. path` entry belong to that submodule.
---@param root string
---@param output string
---@param ret snacks.explorer.git.Status[]
local function parse(root, output, ret)
  local repo = root
  for _, line in ipairs(vim.split(output, "\0")) do
    local submodule = line:sub(1, 1) == SUBMODULE_MARKER and line:sub(2) or nil
    if submodule then
      repo = root .. "/" .. submodule
    else
      local status, file = line:match("^(..) (.+)$")
      if status then
        ret[#ret + 1] = { status = status, file = repo .. "/" .. file }
      end
    end
  end
end

--- Git status of the repo at `root`, including its (nested) submodules.
---@param root string
---@param untracked? boolean
---@param cb fun(ret: snacks.explorer.git.Status[])
local function repo_status(root, untracked, cb)
  local cmds = { status_args(untracked) }
  if uv.fs_stat(root .. "/.gitmodules") then
    -- `--quiet` hides the (localized) "Entering '<path>'" lines,
    -- so print our own marker with the submodule path instead.
    -- `\001` must match SUBMODULE_MARKER
    local cmd = [[printf '\001%s\0' "$displaypath" && git --no-pager --no-optional-locks ]]
      .. table.concat(status_args(untracked), " ")
    cmds[#cmds + 1] = { "submodule", "--quiet", "foreach", "--recursive", cmd }
  end
  local ret = {} ---@type snacks.explorer.git.Status[]
  local pending = #cmds
  for _, args in ipairs(cmds) do
    git(root, args, function(output)
      parse(root, output, ret)
      pending = pending - 1
      if pending == 0 then
        cb(ret)
      end
    end)
  end
end

--- Finds the git repositories below `dir`, without descending into them
--- (their submodules are handled by `repo_status`). Skips hidden directories and `node_modules`.
---@param dir string
---@param depth? number
---@param ret? string[]
---@return string[]
function M.find_repos(dir, depth, ret)
  ret = ret or {}
  depth = depth or 1
  local fd = depth <= MAX_DEPTH and uv.fs_scandir(dir) or nil
  while fd do
    local name, t = uv.fs_scandir_next(fd)
    if not name then
      break
    end
    local path = dir .. "/" .. name
    -- some filesystems don't report the type
    t = t or Snacks.util.path_type(path)
    if t == "directory" and name:sub(1, 1) ~= "." and name ~= "node_modules" then
      if uv.fs_stat(path .. "/.git") then
        ret[#ret + 1] = path
      else
        M.find_repos(path, depth + 1, ret)
      end
    end
  end
  return ret
end

---@param cwd string
local function state_key(cwd)
  return Snacks.git.get_root(cwd) or svim.fs.normalize(cwd)
end

--- Git repositories whose status is shown for `cwd`
---@param cwd string
---@return string[]
function M.roots(cwd)
  local root = Snacks.git.get_root(cwd)
  if root then
    return { root }
  end
  local state = M.state[svim.fs.normalize(cwd)]
  return state and state.repos or {}
end

---@param path string
function M.refresh(path)
  for key, state in pairs(M.state) do
    if path == key or path:find(key .. "/", 1, true) == 1 then
      state.last = 0
      if state.scanned and not M.in_repos(path, state.repos) then
        -- e.g. a repo was cloned or deleted below the cwd
        state.rescan = true
      end
    end
  end
end

--- Whether `path` is one of `repos` or inside one of them
---@param path string
---@param repos string[]
function M.in_repos(path, repos)
  for _, repo in ipairs(repos) do
    if path == repo or path:find(repo .. "/", 1, true) == 1 then
      return true
    end
  end
  return false
end

---@param cwd string
function M.is_dirty(cwd)
  local state = M.state[state_key(cwd)]
  return state == nil or state.last == 0
end

---@param cwd string
---@param opts? {on_update?: fun(), ttl?: number, force?: boolean, untracked?: boolean}
function M.update(cwd, opts)
  opts = opts or {}
  local ttl = opts.ttl or CACHE_TTL
  if opts.force then
    ttl = 0
  end
  local root = Snacks.git.get_root(cwd)
  local key = root or svim.fs.normalize(cwd)
  local now = os.time()
  M.state[key] = M.state[key] or { tick = 0, last = 0, repos = {} }
  local state = M.state[key]
  if now - state.last < ttl then
    return
  end
  state.last = now
  state.tick = state.tick + 1
  local tick = state.tick

  if root then
    state.repos = { root }
  elseif not state.scanned or state.rescan then
    -- not inside a git repo: show the status of all the repos below the cwd.
    -- Scanning is synchronous, so only redo it when the repos may have changed
    -- (see `M.refresh`), not on every git refresh.
    state.repos = M.find_repos(key)
    state.scanned, state.rescan = true, false
  end
  if #state.repos == 0 then
    return M._update(cwd, {})
  end

  local ret = {} ---@type snacks.explorer.git.Status[]
  local pending = #state.repos
  for _, repo in ipairs(state.repos) do
    if repo ~= root then
      ret[#ret + 1] = { status = "!!", file = repo .. "/.git" }
    end
    repo_status(repo, opts.untracked, function(status)
      vim.list_extend(ret, status)
      pending = pending - 1
      if pending > 0 or not M.state[key] or M.state[key].tick ~= tick then
        return
      end
      if M._update(cwd, ret) and opts.on_update then
        vim.schedule(opts.on_update)
      end
    end)
  end
end

---@param cwd string
---@param results snacks.explorer.git.Status[]
function M._update(cwd, results)
  local Tree = require("snacks.explorer.tree")
  local Git = require("snacks.picker.source.git")
  local node = Tree:find(cwd)

  local snapshot = Tree:snapshot(node, { "status", "ignored" })

  Tree:each(node, function(n)
    n.status = nil
    n.ignored = nil
  end)

  ---@param path string
  ---@param status string
  local function add_git_status(path, status)
    local n = Tree:find(path)
    n.status = n.status and Git.merge_status(n.status, status) or status
    if status:sub(1, 1) == "!" then
      n.ignored = true
    end
  end

  if vim.fn.isdirectory(cwd .. "/.git") == 1 then
    add_git_status(cwd .. "/.git", "!!")
  end

  for _, s in ipairs(results) do
    local is_dir = s.file:sub(-1) == "/"
    local path = is_dir and s.file:sub(1, -2) or s.file
    local deleted = s.status:find("D") and s.status ~= "UD"
    if not deleted then
      add_git_status(path, s.status)
    end
    if is_dir then
      local n = Tree:find(path)
      n.dir_status = s.status
    end
    if s.status:sub(1, 1) ~= "!" then -- don't propagate ignored status
      add_git_status(cwd, s.status)
      for dir in Snacks.picker.util.parents(path, cwd) do
        if not s.status:find("^.D$") or vim.fn.isdirectory(dir) == 1 then
          -- only propagate if not deleted or still exists
          add_git_status(dir, s.status)
        end
      end
    end
  end
  return Tree:changed(node, snapshot)
end

---@param cwd string
---@param path? string
---@param up? boolean
function M.next(cwd, path, up)
  local Tree = require("snacks.explorer.tree")
  return Tree:next(cwd, function(node)
    return node.status ~= nil
  end, { up = up, path = path })
end

return M
