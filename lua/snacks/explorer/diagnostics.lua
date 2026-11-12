---@diagnostic disable: missing-fields
local M = {}

-- Set by `DiagnosticChanged`. When clean, `update` for the same cwd is a no-op.
M.dirty = true
M.cwd = nil ---@type string?
-- Nodes that got a severity during the last update
M.severity = {} ---@type table<snacks.picker.explorer.Node, number>
-- Normalized buffer names
local norm_cache = {} ---@type table<string, string>

vim.api.nvim_create_autocmd("DiagnosticChanged", {
  group = vim.api.nvim_create_augroup("snacks.explorer.diagnostics", { clear = true }),
  callback = function()
    M.dirty = true
  end,
})

--- Most severe diagnostic of a buffer.
--- Uses `vim.diagnostic.count`, which, unlike `vim.diagnostic.get`, does not deep-copy every diagnostic.
---@param buf number
---@return number?
local function worst(buf)
  local ret ---@type number?
  if vim.diagnostic.count then
    for severity in pairs(vim.diagnostic.count(buf)) do
      ret = math.min(ret or severity, severity)
    end
  else
    for _, diag in ipairs(vim.diagnostic.get(buf)) do
      local severity = tonumber(diag.severity) or vim.diagnostic.severity.INFO
      ret = math.min(ret or severity, severity)
    end
  end
  return ret
end

---@param cwd string
---@return boolean changed
function M.update(cwd)
  if not M.dirty and M.cwd == cwd then
    return false
  end
  M.dirty, M.cwd = false, cwd

  local Tree = require("snacks.explorer.tree")
  local root = Tree:find(cwd)
  local prefix = cwd:sub(-1) == "/" and cwd or cwd .. "/"

  local severity = {} ---@type table<snacks.picker.explorer.Node, number>
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(buf)
    local path = norm_cache[name]
    if not path and name ~= "" then
      path = svim.fs.normalize(name)
      norm_cache[name] = path
    end
    local s = path and path:sub(1, #prefix) == prefix and worst(buf)
    if s then
      -- propagate to the file, its parents and the cwd
      local node = Tree:find(path) ---@type snacks.picker.explorer.Node?
      while node do
        severity[node] = math.min(severity[node] or s, s)
        node = node ~= root and node.parent or nil
      end
    end
  end

  local changed = false
  for node, s in pairs(M.severity) do
    if severity[node] ~= s then
      changed = true
      node.severity = severity[node]
    end
  end
  for node, s in pairs(severity) do
    if M.severity[node] ~= s then
      changed = true
      node.severity = s
    end
  end
  M.severity = severity
  return changed
end

return M
