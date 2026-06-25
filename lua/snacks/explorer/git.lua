---@diagnostic disable: missing-fields
local M = {}

---@class snacks.explorer.git.Status
---@field status string
---@field file string

local uv = vim.uv or vim.loop

local CACHE_TTL = 15 * 60 -- 15 minutes

M.state = {} ---@type table<string, {tick: number, last: number, results: snacks.explorer.git.Status[]}>

---@param path string
function M.refresh(path)
  for root in pairs(M.state) do
    if path == root or path:find(root .. "/", 1, true) == 1 or root:find(path .. "/", 1, true) == 1 then
      M.state[root].last = 0
    end
  end
end

---@param cwd string
function M.is_dirty(cwd)
  local base_root = Snacks.git.get_root(cwd)
  if base_root and (not M.state[base_root] or M.state[base_root].last == 0) then
    return true
  end
  for root, state in pairs(M.state) do
    if root:find(cwd .. "/", 1, true) == 1 then
      if state.last == 0 then return true end
    end
  end
  return false
end

---@param cwd string
---@param opts? {on_update?: fun(), ttl?: number, force?: boolean, untracked?: boolean}
function M.update(cwd, opts)
  opts = opts or {}
  local ttl = opts.ttl or CACHE_TTL
  if opts.force then
    ttl = 0
  end

  local roots_set = {}
  local base_root = Snacks.git.get_root(cwd)
  if base_root then
    roots_set[base_root] = true
  end
  -- Dynamically discover sub-repos currently loaded in the explorer tree
  local ok, Tree = pcall(require, "snacks.explorer.tree")
  if ok then
    local node = Tree:find(cwd)
    if node then
      Tree:walk(node, function(n)
        if n.dir and vim.fn.isdirectory(n.path .. "/.git") == 1 then
          roots_set[n.path] = true
        end
      end, { all = true })
    end
  end

  local roots = vim.tbl_keys(roots_set)
  if #roots == 0 then
    return M._update(cwd, {})
  end
  local now = os.time()
  local active_roots = {}
  for _, root in ipairs(roots) do
    M.state[root] = M.state[root] or { tick = 0, last = 0, results = {} }
    local state = M.state[root]
    if now - state.last >= ttl then
      state.last = now
      state.tick = state.tick + 1
      table.insert(active_roots, root)
    end
  end
  if #active_roots == 0 then
    return
  end

  local pending = #active_roots

  -- Callback to trigger once ALL active root processes have finished
  local function on_done()
    pending = pending - 1
    if pending == 0 then
      local all_results = {}
      for _, root in ipairs(roots) do
        if M.state[root] and M.state[root].results then
          for _, res in ipairs(M.state[root].results) do
            table.insert(all_results, res)
          end
        end
      end
      if M._update(cwd, all_results) and opts.on_update then
        vim.schedule(opts.on_update)
      end
    end
  end

  -- Concurrently fetch git status for all dirty/expired roots
  for _, root in ipairs(active_roots) do
    local tick = M.state[root].tick
    local output = ""
    local stdout = assert(uv.new_pipe())
    local handle ---@type uv.uv_process_t
    handle = uv.spawn("git", {
      stdio = { nil, stdout, nil },
      cwd = root,
      hide = true,
      args = {
        "--no-pager",
        "--no-optional-locks",
        "status",
        "--porcelain=v1",
        "--ignored=matching",
        "-z",
        opts.untracked and "-unormal" or "-uno",
      },
    }, function()
      handle:close()
    end)

    if not handle then
      on_done()
    else
      stdout:read_start(function(err, data)
        assert(not err, err)
        if data then
          output = output .. data
        else
          stdout:close()
          -- Make sure the result belongs to the current fetch cycle
          if M.state[root].tick == tick then
            local ret = {} ---@type snacks.explorer.git.Status[]
            for _, line in ipairs(vim.split(output, "\0")) do
              if line ~= "" then
                local status, file = line:match("^(..) (.+)$")
                if status then
                  ret[#ret + 1] = {
                    status = status,
                    file = root .. "/" .. file,
                  }
                end
              end
            end
            M.state[root].results = ret -- Cache the results for this specific root
          end
          on_done()
        end
      end)
    end
  end
end

---@param cwd string
---@param results snacks.explorer.git.Status[]
function M._update(cwd, results)
  local Tree = require("snacks.explorer.tree")
  local Git = require("snacks.picker.source.git")
  local node = Tree:find(cwd)
  if not node then return false end
  local snapshot = Tree:snapshot(node, { "status", "ignored" })

  Tree:walk(node, function(n)
    n.status = nil
    n.ignored = nil
  end, { all = true })

  ---@param path string
  ---@param status string
  local function add_git_status(path, status)
    local n = Tree:find(path)
    if not n then return end
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
      if n then n.dir_status = s.status end
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
