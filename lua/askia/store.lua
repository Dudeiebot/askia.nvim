--- Where askia remembers which Claude session belongs to which project.
---
--- Only ids live here -- the conversations themselves are Claude Code's, in
--- ~/.claude/projects. One line per project, pruned on every write, so the file
--- stays a few kilobytes however long you use it.
local M = {}

--- Projects kept at most. Well past what anyone works on in a TTL window, and
--- it bounds the file: ~120 bytes an entry, so ~6 KB at the ceiling.
local MAX_ENTRIES = 50

--- Wall clock with sub-second resolution. os.time() would do, but whole
--- seconds make short TTLs untestable, and vim.uv.now() is time since this
--- Neovim started -- meaningless once written to disk.
function M.now()
  local seconds, micros = vim.uv.gettimeofday()
  return seconds + micros / 1e6
end

function M.path()
  return vim.fs.joinpath(vim.fn.stdpath("state"), "askia", "sessions.json")
end

---@return table<string, { id: string, used: number }>
function M.read()
  local file = io.open(M.path(), "r")
  if not file then return {} end
  local raw = file:read("*a")
  file:close()

  local ok, decoded = pcall(vim.json.decode, raw)
  if not ok or type(decoded) ~= "table" then return {} end
  return decoded
end

--- Drop anything expired or malformed, then keep only the most recent entries.
local function prune(entries, ttl)
  local now, rows = M.now(), {}
  for root, entry in pairs(entries) do
    local usable = type(root) == "string"
      and type(entry) == "table"
      and type(entry.id) == "string"
      and type(entry.used) == "number"
    if usable and (ttl <= 0 or (now - entry.used) <= ttl) then
      table.insert(rows, { root = root, entry = entry })
    end
  end

  table.sort(rows, function(a, b) return a.entry.used > b.entry.used end)

  local kept = {}
  for i = 1, math.min(#rows, MAX_ENTRIES) do
    kept[rows[i].root] = rows[i].entry
  end
  return kept
end

--- Merge one change into whatever is on disk, prune, write it back.
---
--- Read-modify-write rather than dumping our own copy: another Neovim may have
--- recorded a session for a different project since we last looked, and it
--- should survive our write.
---@param root string
---@param entry { id: string, used: number }|nil nil forgets the project
---@param ttl number seconds; 0 disables expiry
---@return table<string, { id: string, used: number }>
function M.update(root, entry, ttl)
  local entries = M.read()
  entries[root] = entry
  entries = prune(entries, ttl)

  local path = M.path()
  vim.fn.mkdir(vim.fs.dirname(path), "p")

  -- Write beside the target and rename over it, so a reader never sees a
  -- half-written file and two writers cannot interleave.
  local tmp = path .. ".tmp"
  local file = io.open(tmp, "w")
  if not file then return entries end
  file:write(vim.json.encode(next(entries) and entries or vim.empty_dict()))
  file:close()
  vim.uv.fs_rename(tmp, path)

  return entries
end

--- Size of the store, for :AskInfo.
function M.stat()
  local stat = vim.uv.fs_stat(M.path())
  return { bytes = stat and stat.size or 0, projects = vim.tbl_count(M.read()) }
end

return M
