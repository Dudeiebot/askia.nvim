--- Extra code attached to the next question: functions from other files that
--- the one you are asking about depends on.
---
--- Ranges are tracked with extmarks rather than remembered as line numbers, so
--- editing a file after marking something still sends the right lines. The text
--- captured at :AskAdd time is kept as a fallback for when the buffer is gone.
local M = {}

local ns = vim.api.nvim_create_namespace("askia.refs")

---@type { path: string, bufnr: integer, mark: integer?, l1: integer, l2: integer, filetype: string, text: string }[]
local items = {}

local function relative(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" then return "[unnamed buffer]" end
  return vim.fn.fnamemodify(name, ":.")
end

---@return table item, integer index
function M.add(bufnr, l1, l2)
  local ok, mark = pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, l1 - 1, 0, {
    end_row = l2 - 1,
    end_col = 0,
  })

  local item = {
    path = relative(bufnr),
    bufnr = bufnr,
    mark = ok and mark or nil,
    l1 = l1,
    l2 = l2,
    filetype = vim.bo[bufnr].filetype,
    text = table.concat(vim.api.nvim_buf_get_lines(bufnr, l1 - 1, l2, false), "\n"),
  }

  -- Marking the same lines twice refreshes that entry instead of stacking.
  for i, existing in ipairs(items) do
    if existing.path == item.path and existing.l1 == l1 and existing.l2 == l2 then
      items[i] = item
      return item, i
    end
  end

  table.insert(items, item)
  return item, #items
end

--- The references as they stand right now, following any edits since.
---@return { path: string, l1: integer, l2: integer, filetype: string, text: string }[]
function M.resolve()
  local out = {}
  for _, item in ipairs(items) do
    local l1, l2, text = item.l1, item.l2, item.text

    if item.mark and vim.api.nvim_buf_is_valid(item.bufnr) then
      local ok, pos = pcall(
        vim.api.nvim_buf_get_extmark_by_id,
        item.bufnr,
        ns,
        item.mark,
        { details = true }
      )
      if ok and pos and pos[1] then
        l1 = pos[1] + 1
        l2 = ((pos[3] and pos[3].end_row) or pos[1]) + 1
        local lines = vim.api.nvim_buf_get_lines(item.bufnr, l1 - 1, l2, false)
        if #lines > 0 then text = table.concat(lines, "\n") end
      end
    end

    table.insert(out, {
      path = item.path,
      l1 = l1,
      l2 = l2,
      filetype = item.filetype,
      text = text,
    })
  end
  return out
end

function M.count()
  return #items
end

---@return string[] one line per reference, for :AskInfo
function M.summary()
  local lines = {}
  for i, ref in ipairs(M.resolve()) do
    table.insert(lines, ("%d. %s (%d-%d)"):format(i, ref.path, ref.l1, ref.l2))
  end
  return lines
end

function M.clear()
  for _, item in ipairs(items) do
    if item.mark and vim.api.nvim_buf_is_valid(item.bufnr) then
      pcall(vim.api.nvim_buf_del_extmark, item.bufnr, ns, item.mark)
    end
  end
  items = {}
end

return M
