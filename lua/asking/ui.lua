local config = require("asking.config")

local M = {}

local SPINNER = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local ns = vim.api.nvim_create_namespace("asking")

---@type table
local state = {
  win = nil,
  buf = nil,
  geometry = nil,
  blocks = {},   -- { kind = "text"|"tool"|"ask", text = string }
  label = "",
  status = nil,  -- non-nil while a request is in flight
  frame = 1,
  dirty = false,
  timer = nil,
  handlers = {}, -- { on_follow, on_cancel }
}

local function is_open()
  return state.win and vim.api.nvim_win_is_valid(state.win)
end

local function flatten()
  local lines, tool_rows = {}, {}
  for _, block in ipairs(state.blocks) do
    if block.kind == "tool" then
      tool_rows[#lines] = true -- 0-indexed row of the line we're about to add
      table.insert(lines, "⏺ " .. block.text)
    elseif block.kind == "ask" then
      if #lines > 0 then table.insert(lines, "") end
      for _, l in ipairs(vim.split(block.text, "\n", { plain = true })) do
        table.insert(lines, "> " .. l)
      end
      table.insert(lines, "")
    else
      vim.list_extend(lines, vim.split(block.text, "\n", { plain = true }))
    end
  end
  if #lines == 0 then lines = { "" } end
  return lines, tool_rows
end

local function footer_text()
  if state.status then
    return (" %s %s  ·  <C-c> cancel "):format(SPINNER[state.frame], state.status)
  end
  return (" %s  ·  Press Enter to follow up  ·  y yank  ·  q close "):format(state.label)
end

local function apply_footer()
  if not is_open() or not state.geometry.border or state.geometry.border == "none" then return end
  local text = footer_text()
  local max = state.geometry.width - 2
  if vim.fn.strchars(text) > max then
    text = vim.fn.strcharpart(text, 0, max)
  end
  local cfg = vim.tbl_extend("force", state.geometry, {
    footer = { { text, state.status and "DiagnosticInfo" or "Comment" } },
    footer_pos = "right",
  })
  pcall(vim.api.nvim_win_set_config, state.win, cfg)
end

local function render()
  if not (state.buf and vim.api.nvim_buf_is_valid(state.buf)) then return end
  local lines, tool_rows = flatten()

  local follow = false
  if is_open() then
    local cursor = vim.api.nvim_win_get_cursor(state.win)[1]
    follow = cursor >= vim.api.nvim_buf_line_count(state.buf) - 1
  end

  vim.bo[state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
  vim.bo[state.buf].modifiable = false

  vim.api.nvim_buf_clear_namespace(state.buf, ns, 0, -1)
  for row in pairs(tool_rows) do
    pcall(vim.api.nvim_buf_set_extmark, state.buf, ns, row, 0, {
      end_col = #lines[row + 1],
      hl_group = "Comment",
    })
  end

  if is_open() and follow then
    pcall(vim.api.nvim_win_set_cursor, state.win, { #lines, 0 })
  end
end

local function tick()
  if state.status then
    state.frame = state.frame % #SPINNER + 1
    apply_footer()
  end
  if state.dirty then
    state.dirty = false
    render()
  end
end

local function start_timer()
  if state.timer then return end
  state.timer = vim.uv.new_timer()
  state.timer:start(0, 80, vim.schedule_wrap(tick))
end

local function stop_timer()
  if state.timer then
    state.timer:stop()
    state.timer:close()
    state.timer = nil
  end
end

function M.close()
  stop_timer()
  if is_open() then vim.api.nvim_win_close(state.win, true) end
  state.win = nil
end

local function answer_text()
  local parts = {}
  for _, block in ipairs(state.blocks) do
    if block.kind == "text" then table.insert(parts, block.text) end
  end
  return vim.trim(table.concat(parts))
end

local function setup_buffer()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].modifiable = false

  local function map(lhs, fn)
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true })
  end
  map("q", M.close)
  map("<Esc>", M.close)
  map("<C-c>", function()
    if state.handlers.on_cancel then state.handlers.on_cancel() end
  end)
  map("<CR>", function()
    if not state.handlers.on_follow then return end
    vim.ui.input({ prompt = "follow up: " }, function(input)
      if input and vim.trim(input) ~= "" then state.handlers.on_follow(vim.trim(input)) end
    end)
  end)
  map("y", function()
    local text = answer_text()
    vim.fn.setreg('"', text)
    if vim.fn.has("clipboard") == 1 then vim.fn.setreg("+", text) end
    vim.notify("answer yanked", vim.log.levels.INFO)
  end)

  return buf
end

local function open_window(buf)
  local win_cfg = config.options.window
  local width = math.floor(vim.o.columns * win_cfg.width)
  local height = math.floor((vim.o.lines - vim.o.cmdheight) * win_cfg.height)

  state.geometry = {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2) - 1,
    col = math.floor((vim.o.columns - width) / 2),
    border = win_cfg.border,
    style = "minimal",
    title = " claude ",
    title_pos = "left",
  }

  local win = vim.api.nvim_open_win(buf, true, state.geometry)
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].conceallevel = 2
  vim.wo[win].cursorline = false
  return win
end

--- Start a fresh answer in a fresh window.
---@param opts { question: string, label: string, on_follow: fun(q: string), on_cancel: fun() }
function M.open(opts)
  M.close()
  state.blocks = { { kind = "ask", text = opts.question } }
  state.label = opts.label
  state.status = "thinking"
  state.frame = 1
  state.handlers = { on_follow = opts.on_follow, on_cancel = opts.on_cancel }

  state.buf = setup_buffer()
  state.win = open_window(state.buf)

  render()
  apply_footer()
  start_timer()
end

--- Append a follow-up question to the window that's already open.
function M.append_question(question)
  table.insert(state.blocks, { kind = "ask", text = question })
  state.status = "thinking"
  state.dirty = true
  start_timer()
end

function M.append_text(chunk)
  if chunk == "" then return end
  local last = state.blocks[#state.blocks]
  if last and last.kind == "text" then
    last.text = last.text .. chunk
  else
    table.insert(state.blocks, { kind = "text", text = chunk })
  end
  state.status = "writing"
  state.dirty = true
end

function M.append_tool(line)
  if config.options.window.show_tools then
    table.insert(state.blocks, { kind = "tool", text = line })
    state.dirty = true
  end
  state.status = line
end

---@param err string?
function M.finish(err)
  state.status = nil
  if err then
    table.insert(state.blocks, { kind = "text", text = "\n\n**error:** " .. err })
  end
  render()
  apply_footer()
  stop_timer()
end

function M.is_open()
  return is_open()
end

--- The scratch buffer answers are rendered into, if any.
function M.answer_buf()
  return state.buf
end

return M
