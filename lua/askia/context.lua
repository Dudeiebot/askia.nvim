local M = {}

--- Walk up the syntax tree until we hit something function-shaped.
--- Works across languages without special-casing because the node types all
--- contain "function" or "method": Rust `function_item`, Go
--- `function_declaration` / `method_declaration`, Python `function_definition`,
--- Lua `function_declaration`, TS `method_definition` / `arrow_function`.
--- `class` is included as a last resort for cursors parked on a field.
---@return integer? start_line 1-indexed, inclusive
---@return integer? end_line 1-indexed, inclusive
function M.enclosing_function(bufnr)
  -- get_node returns nil until something has actually parsed the buffer, so
  -- this fails silently in any buffer where treesitter highlighting is off.
  -- Parse first, and treat a missing parser as "no function here".
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr)
  if not ok or not parser then return nil end
  pcall(parser.parse, parser)

  local node
  ok, node = pcall(vim.treesitter.get_node, { bufnr = bufnr })
  if not ok or not node then return nil end

  while node do
    local t = node:type()
    if t:match("function") or t:match("method") or t:match("class") then
      local srow, _, erow, ecol = node:range()
      -- A node ending at column 0 stops on the line *after* its last one.
      if ecol == 0 and erow > srow then erow = erow - 1 end
      return srow + 1, erow + 1
    end
    node = node:parent()
  end
end

--- A fence longer than any backtick run in the code, so snippets containing
--- markdown of their own don't break out of the block.
local function fence_for(code)
  local longest = 2
  for run in code:gmatch("`+") do
    longest = math.max(longest, #run)
  end
  return string.rep("`", longest + 1)
end

--- One labelled, fenced block.
local function block(label, code, filetype)
  local fence = fence_for(code)
  return table.concat({ label, "", fence .. (filetype or ""), code, fence, "" }, "\n")
end

---@param references { path: string, l1: integer, l2: integer, filetype: string, text: string }[]?
---@return string prompt, string label
function M.build_prompt(bufnr, l1, l2, question, references)
  local code = table.concat(vim.api.nvim_buf_get_lines(bufnr, l1 - 1, l2, false), "\n")
  local name = vim.api.nvim_buf_get_name(bufnr)
  local where = name ~= "" and vim.fn.fnamemodify(name, ":.") or "[unnamed buffer]"

  local parts, attached = {}, 0
  -- References first, so the code actually being asked about sits closest to
  -- the question.
  local blocks = {}
  for _, ref in ipairs(references or {}) do
    -- Marking a function and then asking about it would otherwise send the
    -- same lines twice, once as a reference and once as the subject.
    local duplicate = ref.path == where and ref.l1 >= l1 and ref.l2 <= l2
    if not duplicate then
      attached = attached + 1
      table.insert(blocks, block(
        ("Reference: %s (lines %d-%d)"):format(ref.path, ref.l1, ref.l2),
        ref.text,
        ref.filetype
      ))
    end
  end

  if attached > 0 then
    table.insert(parts, ("Attached for this question, %d reference%s from elsewhere in the codebase:")
      :format(attached, attached == 1 and "" or "s"))
    table.insert(parts, "")
    vim.list_extend(parts, blocks)
  end

  table.insert(parts, block(
    ("File: %s (lines %d-%d)"):format(where, l1, l2),
    code,
    vim.bo[bufnr].filetype
  ))
  table.insert(parts, question)

  local label = ("%s:%d-%d"):format(vim.fn.fnamemodify(where, ":t"), l1, l2)
  if attached > 0 then
    label = ("%s · %d ref%s"):format(label, attached, attached == 1 and "" or "s")
  end

  return table.concat(parts, "\n"), label
end

return M
