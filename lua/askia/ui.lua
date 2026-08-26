local config = require("askia.config")

local M = {}

local SPINNER = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local PROMPT = "❯ "
local ns = vim.api.nvim_create_namespace("askia")
local augroup = vim.api.nvim_create_augroup("askia", { clear = true })

local state = {
  win = nil,
  buf = nil,
  geometry = nil, -- the table handed to nvim_win_set_config
  size = {}, -- width/height the user chose by hand; nil means "follow config"
  max_height = 0, -- ceiling for auto-fit
  maximized = false,
  pre_max = nil,
  blocks = {}, -- { kind = "text"|"tool"|"ask", text = string }
  label = "",
  status = nil, -- non-nil while a request is in flight
  frame = 1,
  dirty = false,
  timer = nil,
  handlers = {}, -- { on_follow, on_cancel, on_quit, on_terminal }
  cursor = nil, -- restored when the window is reopened
  prompt = nil, -- the follow-up being typed, as a string; nil when not asking
}

local open_window -- defined below; declared here so the resize helpers can reach it

local function is_open() return state.win and vim.api.nvim_win_is_valid(state.win) end

local function has_buf() return state.buf and vim.api.nvim_buf_is_valid(state.buf) end

-- ---------------------------------------------------------------- geometry --

--- Space the float is allowed to occupy, leaving the command line alone.
local function editor_size() return vim.o.columns, vim.o.lines - vim.o.cmdheight - 1 end

--- The size a new window opens at: what the user last chose by hand, else the
--- configured fractions, always inside the editor.
local function wanted_size()
  local win_cfg = config.options.window
  local cols, rows = editor_size()
  local width = state.size.width or math.floor(cols * win_cfg.width)
  local height = state.size.height or math.floor(rows * win_cfg.height)
  return math.max(24, math.min(width, cols - 2)),
    math.max(win_cfg.min_height, math.min(height, rows - 2))
end

local function footer_text()
  if state.prompt ~= nil then return " <CR> send  ·  <Esc> back  ·  q discard " end
  if state.status then
    return (" %s %s  ·  <C-c> cancel "):format(SPINNER[state.frame], state.status)
  end
  return (" %s  ·  <CR> follow  ·  q hide  ·  Q quit  ·  ? keys "):format(state.label)
end

--- Push state.geometry (plus the live footer) at the window.
local function apply_win_config()
  if not is_open() then return end

  local cfg = vim.deepcopy(state.geometry)
  if cfg.border and cfg.border ~= "none" then
    local text = footer_text()
    local room = cfg.width - 2
    if vim.fn.strchars(text) > room then text = vim.fn.strcharpart(text, 0, room) end
    cfg.footer = { { text, state.status and "DiagnosticInfo" or "Comment" } }
    cfg.footer_pos = "right"
  end
  pcall(vim.api.nvim_win_set_config, state.win, cfg)
end

--- Grow the window to fit its content, up to the ceiling. The top edge stays
--- put so growth happens downwards instead of the window jumping around.
local function fit_height()
  if not is_open() then return end
  if not config.options.window.auto_height or state.size.height then return end

  local ok, measured = pcall(vim.api.nvim_win_text_height, state.win, {})
  if not ok then return end

  local height =
    math.max(config.options.window.min_height, math.min(measured.all, state.max_height))
  if height ~= state.geometry.height then
    state.geometry.height = height
    apply_win_config()
  end
end

--- Reopen at the current size settings, keeping the cursor where it was.
local function relayout()
  if not (is_open() and has_buf()) then return end
  local cursor = vim.api.nvim_win_get_cursor(state.win)
  vim.api.nvim_win_close(state.win, true)
  state.win = open_window(state.buf)
  pcall(vim.api.nvim_win_set_cursor, state.win, cursor)
  fit_height()
  apply_win_config()
end

---@param dw integer columns
---@param dh integer rows
local function resize(dw, dh)
  if not is_open() then return end
  local cols, rows = editor_size()

  -- Choosing a height by hand turns auto-fit off until `=`.
  state.size.width = math.max(24, math.min(state.geometry.width + dw, cols - 2))
  state.size.height =
    math.max(config.options.window.min_height, math.min(state.geometry.height + dh, rows - 2))
  state.maximized = false

  state.geometry.width = state.size.width
  state.geometry.height = state.size.height
  state.geometry.col = math.floor((cols - state.geometry.width) / 2)
  state.geometry.row = math.max(0, math.min(state.geometry.row, rows - state.geometry.height))
  state.max_height = state.size.height
  apply_win_config()
end

local function reset_size()
  state.size = {}
  state.maximized = false
  relayout()
end

local function toggle_maximize()
  if state.maximized then
    state.size = state.pre_max or {}
    state.maximized = false
  else
    local cols, rows = editor_size()
    state.pre_max = vim.deepcopy(state.size)
    state.size = { width = cols - 2, height = rows - 2 }
    state.maximized = true
  end
  relayout()
end

vim.api.nvim_create_autocmd("VimResized", {
  group = augroup,
  desc = "keep the askia window inside the editor",
  callback = function()
    if is_open() then
      -- A hand-picked size may no longer fit the smaller editor.
      state.size.width = nil
      state.size.height = nil
      relayout()
    end
  end,
})

-- ------------------------------------------------------------------ render --

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
  return lines, tool_rows
end

local function render()
  if not has_buf() then return end
  local lines, tool_rows = flatten()

  local prompt_row
  if state.prompt ~= nil then
    -- Only separate the prompt from a transcript that exists: composing a first
    -- question starts on an empty buffer.
    if #lines > 0 then table.insert(lines, "") end
    prompt_row = #lines -- 0-indexed row of the line about to be added
    table.insert(lines, PROMPT .. state.prompt)
  end
  if #lines == 0 then lines = { "" } end

  local follow, held, on_prompt = false, nil, false
  if is_open() then
    local cursor = vim.api.nvim_win_get_cursor(state.win)
    local count = vim.api.nvim_buf_line_count(state.buf)
    follow = cursor[1] >= count - 1
    held = cursor -- typing a follow-up must not be interrupted by the stream
    -- The prompt is always the last line, and text arriving above pushes it
    -- down: follow it, rather than holding an absolute row.
    on_prompt = state.prompt ~= nil and cursor[1] == count
  end

  vim.bo[state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
  -- Stays editable while a follow-up is being typed.
  vim.bo[state.buf].modifiable = state.prompt ~= nil

  vim.api.nvim_buf_clear_namespace(state.buf, ns, 0, -1)
  for row in pairs(tool_rows) do
    pcall(vim.api.nvim_buf_set_extmark, state.buf, ns, row, 0, {
      end_col = #lines[row + 1],
      hl_group = "Comment",
    })
  end

  if prompt_row then
    pcall(vim.api.nvim_buf_set_extmark, state.buf, ns, prompt_row, 0, {
      end_col = #PROMPT,
      hl_group = "Question",
    })
  end

  fit_height()
  if not is_open() then return end

  if state.prompt ~= nil then
    if on_prompt then
      pcall(vim.api.nvim_win_set_cursor, state.win, { #lines, held[2] })
    elseif held then
      pcall(vim.api.nvim_win_set_cursor, state.win, {
        math.min(held[1], #lines),
        held[2],
      })
    end
  elseif follow then
    pcall(vim.api.nvim_win_set_cursor, state.win, { #lines, 0 })
  end
end

local function tick()
  if state.status then
    state.frame = state.frame % #SPINNER + 1
    apply_win_config()
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

-- ------------------------------------------------------------- open / shut --

--- Put the window away without losing the answer. Anything still streaming
--- keeps streaming into the hidden buffer.
function M.hide()
  if is_open() then
    state.cursor = vim.api.nvim_win_get_cursor(state.win)
    vim.api.nvim_win_close(state.win, true)
  end
  state.win = nil
end

--- Hide the window and throw the answer away.
function M.close()
  M.hide()
  stop_timer()
  if has_buf() then vim.api.nvim_buf_delete(state.buf, { force = true }) end
  state.buf = nil
  state.blocks = {}
  state.status = nil
end

--- Bring the last answer back, or put it away if it is already up.
function M.toggle()
  if is_open() then
    M.hide()
    return true
  end
  if not has_buf() then return false end

  state.win = open_window(state.buf)
  if state.cursor then pcall(vim.api.nvim_win_set_cursor, state.win, state.cursor) end
  fit_height()
  apply_win_config()
  return true
end

local function answer_text()
  local parts = {}
  for _, block in ipairs(state.blocks) do
    if block.kind == "text" then table.insert(parts, block.text) end
  end
  return vim.trim(table.concat(parts))
end

--- Read back what has been typed on the prompt line.
local function sync_prompt()
  if state.prompt == nil or not has_buf() then return end
  local last = vim.api.nvim_buf_line_count(state.buf)
  local line = vim.api.nvim_buf_get_lines(state.buf, last - 1, last, false)[1] or ""
  if line:sub(1, #PROMPT) == PROMPT then line = line:sub(#PROMPT + 1) end
  state.prompt = line
end

---@param initial string? text to pre-fill the prompt with
local function start_prompt(initial)
  if not (is_open() and state.handlers.on_follow) then return end
  state.prompt = initial or ""
  render()
  apply_win_config()
  local last = vim.api.nvim_buf_line_count(state.buf)
  pcall(vim.api.nvim_win_set_cursor, state.win, { last, #PROMPT })
  vim.cmd("startinsert!")
end

local function cancel_prompt()
  if state.prompt == nil then return false end
  state.prompt = nil
  if vim.fn.mode():find("i") then vim.cmd("stopinsert") end

  -- Backing out of a first question leaves an empty window; close it instead.
  if #state.blocks == 0 then
    M.close()
    return true
  end

  render()
  apply_win_config()
  return true
end

local function submit_prompt()
  sync_prompt()
  local question = vim.trim(state.prompt or "")
  state.prompt = nil
  if vim.fn.mode():find("i") then vim.cmd("stopinsert") end
  render()
  apply_win_config()
  if question ~= "" and state.handlers.on_follow then state.handlers.on_follow(question) end
end

local KEYS = {
  "<CR>  follow-up question, typed in the window",
  "y     yank the answer",
  "t     continue in an interactive claude session",
  "+ -   taller / shorter",
  "> <   wider / narrower",
  "M     maximize (toggle)",
  "=     back to the configured size",
  "q     hide (:AskToggle brings it back)",
  "Q     quit and discard the answer",
  "<C-c> cancel the request in flight",
}

local function setup_buffer()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].modifiable = false
  vim.b[buf].askia = true

  local function map(lhs, fn)
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true })
  end

  map("q", function()
    if not cancel_prompt() then M.hide() end
  end)
  map("<Esc>", function()
    if not cancel_prompt() then M.hide() end
  end)
  map("Q", function()
    if state.handlers.on_quit then
      state.handlers.on_quit()
    else
      M.close()
    end
  end)
  map("<C-c>", function()
    if state.handlers.on_cancel then state.handlers.on_cancel() end
  end)
  map("<CR>", function()
    if state.prompt ~= nil then
      submit_prompt()
    else
      start_prompt()
    end
  end)
  -- Not an expr mapping: those run under textlock, which forbids the buffer
  -- write and the stopinsert that sending a follow-up needs.
  vim.keymap.set("i", "<CR>", function()
    if state.prompt ~= nil then submit_prompt() end
  end, { buffer = buf, silent = true })

  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "InsertLeave" }, {
    buffer = buf,
    group = augroup,
    callback = sync_prompt,
  })
  map("y", function()
    local text = answer_text()
    vim.fn.setreg('"', text)
    if vim.fn.has("clipboard") == 1 then vim.fn.setreg("+", text) end
    vim.notify("askia: answer yanked", vim.log.levels.INFO)
  end)

  map("+", function() resize(0, 2) end)
  map("-", function() resize(0, -2) end)
  map(">", function() resize(8, 0) end)
  map("<", function() resize(-8, 0) end)
  map("t", function()
    if state.handlers.on_terminal then state.handlers.on_terminal() end
  end)
  map("=", reset_size)
  map("M", toggle_maximize)
  map("?", function() vim.notify(table.concat(KEYS, "\n"), vim.log.levels.INFO) end)

  -- <Tab> is <C-i>, a jumplist jump: in a float it yanks some other file into
  -- this window. 'winfixbuf' below refuses the switch, these keep it quiet.
  for _, lhs in ipairs({ "<Tab>", "<S-Tab>", "<C-i>", "<C-o>", "<C-^>", "gf", "<C-]>" }) do
    map(lhs, function() end)
  end

  return buf
end

function open_window(buf)
  local win_cfg = config.options.window
  local cols, rows = editor_size()
  local width, height = wanted_size()

  state.max_height = height
  state.geometry = {
    relative = "editor",
    width = width,
    -- Auto-fit starts small and grows; the row below is computed for the full
    -- height either way, so the top edge never moves as the answer arrives.
    height = win_cfg.auto_height and not state.size.height and math.max(
      win_cfg.min_height,
      math.min(3, height)
    ) or height,
    row = math.max(0, math.floor((rows - height) / 2)),
    col = math.floor((cols - width) / 2),
    border = win_cfg.border,
    style = "minimal",
    title = " claude ",
    title_pos = "left",
  }

  local win = vim.api.nvim_open_win(buf, true, state.geometry)
  -- The real guard: nothing may swap the buffer out of this window, however
  -- the user gets there (jumps, :bnext, a plugin).
  pcall(function() vim.wo[win].winfixbuf = true end)
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].conceallevel = 2
  vim.wo[win].cursorline = false
  return win
end

--- Start a fresh answer in a fresh window.
--- Open a window for an answer, or -- given `draft` -- for a question still
--- being written, where nothing is sent until it is submitted.
---@param opts { question: string?, draft: string?, label: string, on_follow: fun(q: string), on_cancel: fun(), on_quit: fun()?, on_terminal: fun()? }
function M.open(opts)
  M.close()
  state.blocks = opts.question and { { kind = "ask", text = opts.question } } or {}
  state.label = opts.label
  state.status = opts.question and "thinking" or nil
  state.frame = 1
  state.cursor = nil
  state.handlers = {
    on_follow = opts.on_follow,
    on_cancel = opts.on_cancel,
    on_quit = opts.on_quit,
    on_terminal = opts.on_terminal,
  }

  state.buf = setup_buffer()
  state.win = open_window(state.buf)

  render()
  apply_win_config()

  if opts.draft ~= nil then
    start_prompt(opts.draft)
  else
    start_timer()
  end
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
  if err then table.insert(state.blocks, { kind = "text", text = "\n\n**error:** " .. err }) end
  render()
  apply_win_config()
  stop_timer()
end

function M.is_open() return is_open() end

--- The scratch buffer answers are rendered into, if any.
function M.answer_buf() return state.buf end

--- Current window size, for tests and :AskInfo-ish callers.
function M.dimensions()
  if not is_open() then return nil end
  return { width = state.geometry.width, height = state.geometry.height }
end

return M
