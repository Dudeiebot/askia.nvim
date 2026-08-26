local ROOT = assert(os.getenv("ASKING_ROOT"), "run me via tests/run.sh")
vim.opt.runtimepath:append(ROOT)
dofile(ROOT .. "/plugin/asking.lua")

local SP = ROOT .. "/tests"
local asking = require("asking")
local ui = require("asking.ui")

asking.setup({
  cmd = SP .. "/fake-claude",
  allowed_tools = { "Read", "Grep" },
  model = "sonnet",
})

-- allowed_tools must be replaced wholesale, not index-merged with the default.
assert(#require("asking.config").options.allowed_tools == 2, "allowed_tools leaked a default")

vim.cmd.edit(SP .. "/fixtures/greeter.lua")
vim.bo.filetype = "lua"

local done, err_out = false, nil
local orig_finish = ui.finish
ui.finish = function(e) orig_finish(e); done = true; err_out = e end

local function read_argv()
  local f = assert(io.open(assert(os.getenv("ASKING_ARGV_LOG")), "rb"))
  local raw = f:read("*a")
  f:close()
  local out = vim.split(raw, "\0", { plain = true })
  table.remove(out) -- trailing empty field after the last NUL
  return out
end

local function run(fn, what)
  done = false
  fn()
  assert(vim.wait(15000, function() return done end, 30), what .. ": timed out")
  assert(not err_out, what .. ": " .. tostring(err_out))
  local buf = vim.api.nvim_win_get_buf(vim.api.nvim_get_current_win())
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

-- 1. cursor inside the method body, no range: treesitter should find it.
vim.api.nvim_win_set_cursor(0, { 8, 4 })
local lines = run(function()
  vim.cmd("Ask why does this take self by value?")
end, "cursor mode")

print("=== window after cursor-mode ask ===")
print(table.concat(lines, "\n"))

local argv = read_argv()
print("\n=== argv ===\n" .. table.concat(argv, "\n"))

local prompt = argv[2]
assert(prompt:match("lines 7%-11"), "wrong range in prompt:\n" .. prompt)
assert(prompt:match("```lua"), "missing fenced lua block:\n" .. prompt)
assert(prompt:match("M.greet"), "snippet missing the function body")
assert(prompt:match("why does this take self by value%?$"), "question not appended")
assert(prompt:match("File: fixtures/greeter%.lua"), "path not relative to cwd:\n" .. prompt)
assert(vim.tbl_contains(argv, "--allowedTools") and vim.tbl_contains(argv, "Read,Grep"))
assert(vim.tbl_contains(argv, "--model") and vim.tbl_contains(argv, "sonnet"))
assert(not vim.tbl_contains(argv, "--resume"), "first call should not resume")

local body = table.concat(lines, "\n")
assert(body:match("^> why does this take self by value%?"), "question header missing")
assert(body:match("It takes `self` by value%."), "streamed text missing")
assert(body:match("⏺ Grep%(M.greet%)"), "tool line missing")
assert(not body:match("SHOULD NOT APPEAR"), "thinking deltas leaked into the answer")

-- 2. follow-up must resume the same session and keep the window.
lines = run(function() asking.follow_up("and if it took &self?") end, "follow-up")
argv = read_argv()
assert(vim.tbl_contains(argv, "--resume"), "follow-up did not resume")
assert(vim.tbl_contains(argv, "11111111-2222-3333-4444-555555555555"), "wrong session id")
assert(argv[2] == "and if it took &self?", "follow-up sent the whole snippet again")
body = table.concat(lines, "\n")
assert(body:match("> why does this take"), "follow-up lost the earlier turn")
assert(body:match("> and if it took &self%?"), "follow-up question missing")

print("\n=== window after follow-up ===")
print(body)

-- 3. :Ask from inside the answer window is refused, not misdirected.
local warned = false
local orig_notify = vim.notify
vim.notify = function(msg, lvl) if msg:match("run :Ask from a code buffer") then warned = true end end
vim.cmd("Ask")
vim.notify = orig_notify
assert(warned, ":Ask inside the answer window was not refused")
print("answer-window guard ok")

-- 4. visual range wins over treesitter.
ui.close()
vim.cmd.edit(SP .. "/fixtures/greeter.lua")
vim.bo.filetype = "lua"
vim.api.nvim_win_set_cursor(0, { 8, 0 })
run(function() vim.cmd("1,3Ask what is this") end, "range mode")
argv = read_argv()
assert(argv[2]:match("lines 1%-3"), "explicit range ignored:\n" .. argv[2])

-- 5. bare :Ask with no range and no question uses the default question.
ui.close()
vim.cmd.edit(SP .. "/fixtures/greeter.lua")
vim.bo.filetype = "lua"
vim.api.nvim_win_set_cursor(0, { 8, 0 })
run(function() vim.cmd("Ask") end, "default question")
argv = read_argv()
assert(argv[2]:match("Explain what this does and why%.$"), "default question missing")



-- 6. a second language family, to confirm the node-type match is not lua-specific.
ui.close()
vim.cmd.edit(SP .. "/fixtures/greet.c")
vim.bo.filetype = "c"
vim.api.nvim_win_set_cursor(0, { 4, 8 })
local c1, c2 = require("asking.context").enclosing_function(0)
assert(c1 == 3 and c2 == 6, ("c function range wrong: %s-%s"):format(c1, c2))
print("c enclosing_function: lines " .. c1 .. "-" .. c2)

-- 7. a snippet containing its own fence must not break out of the code block.
vim.cmd.enew()
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "```", "inner", "```" })
local p = require("asking.context").build_prompt(0, 1, 3, "q")
assert(p:match("````"), "fence not widened for backtick-containing code:\n" .. p)
print("fence widened ok")

print("\nALL ASSERTIONS PASSED")

-- 8. the promises the README makes to people installing this.
assert(vim.fn.exists(":Ask") == 2, ":Ask must exist without calling setup()")
assert(vim.fn.exists(":AskFollow") == 2 and vim.fn.exists(":AskCancel") == 2)
assert(vim.fn.maparg("<leader>aa", "n") == "", "a default mapping was claimed")
assert(vim.fn.maparg("<leader>aa", "x") == "", "a default mapping was claimed")

-- setup() with no arguments must not throw, and must leave defaults intact.
require("asking.config").setup()
assert(require("asking.config").options.cmd ~= nil)
print("public surface ok")

-- 9. sessions are reused per project root, so a later :Ask picks up what the
--    earlier one already learned.
local asking = require("asking")
asking.reset_session()
ui.close()
vim.cmd.edit(SP .. "/fixtures/greeter.lua")
vim.bo.filetype = "lua"
vim.api.nvim_win_set_cursor(0, { 8, 0 })

run(function() vim.cmd("Ask first question") end, "session: cold start")
assert(not vim.tbl_contains(read_argv(), "--resume"), "cold start must not resume")

local function ask_again(cmd, what)
  ui.close()
  vim.cmd.edit(SP .. "/fixtures/greeter.lua")
  vim.bo.filetype = "lua"
  vim.api.nvim_win_set_cursor(0, { 8, 0 })
  run(function() vim.cmd(cmd) end, what)
  return read_argv()
end

local argv2 = ask_again("Ask second question", "session: reuse")
local i = vim.fn.index(argv2, "--resume")
assert(i >= 0, "second :Ask in the same project did not reuse the session")
assert(argv2[i + 2] == "11111111-2222-3333-4444-555555555555", "wrong session id reused")

-- 10. :Ask! ignores the stored session.
assert(not vim.tbl_contains(ask_again("Ask! third question", "session: bang"), "--resume"),
  ":Ask! must start cold")

-- 11. session = "question" never reuses.
require("asking.config").setup({ session = "question" })
assert(not vim.tbl_contains(ask_again("Ask fourth", "session: per-question"), "--resume"),
  'session = "question" must never resume')

-- 12. a session past its ttl is abandoned rather than resumed.
require("asking.config").setup({ session = "project", session_ttl = 0.0001 }) -- ~6ms
ask_again("Ask fifth", "session: ttl warm-up")
vim.wait(50)
assert(not vim.tbl_contains(ask_again("Ask sixth", "session: ttl"), "--resume"),
  "an expired session must not be resumed")
require("asking.config").setup({ session_ttl = 30 })
print("session handling ok")

-- 13. the window can be put away and brought back with the answer intact.
local answer_buf = ui.answer_buf()
local before = vim.api.nvim_buf_get_lines(answer_buf, 0, -1, false)
assert(ui.toggle() == true, "toggle should hide an open window")
assert(not ui.is_open(), "window still open after toggle")
assert(vim.api.nvim_buf_is_valid(answer_buf), "hiding must not destroy the answer")
assert(ui.toggle() == true, "toggle should bring it back")
assert(ui.is_open(), "window did not come back")
assert(vim.deep_equal(vim.api.nvim_buf_get_lines(ui.answer_buf(), 0, -1, false), before),
  "answer changed across hide/restore")

-- and nothing may swap the buffer out of that window (the <Tab> jumplist bug).
local win = vim.api.nvim_get_current_win()
if vim.fn.exists("&winfixbuf") == 1 then
  assert(vim.wo[win].winfixbuf == true, "winfixbuf not set on the answer window")
end
ui.close()
assert(not vim.api.nvim_buf_is_valid(answer_buf), "close should destroy the answer buffer")
assert(ui.toggle() == false, "nothing to restore after close")
print("hide/restore ok")

-- 14. a stored session id that claude no longer knows about must not strand
--     the question: drop it and retry cold, once.
require("asking.config").setup({ session = "project", session_ttl = 30 })
asking.reset_session()
ask_again("Ask warm up the session", "stale: warm-up")

local marker = vim.fn.tempname()
vim.fn.setenv("ASKING_FAIL_RESUME", marker)
local argv_after = ask_again("Ask after the session went stale", "stale: recovery")
vim.fn.setenv("ASKING_FAIL_RESUME", vim.NIL)

assert(vim.fn.filereadable(marker) == 1, "the stub never saw a --resume to reject")
assert(not vim.tbl_contains(argv_after, "--resume"), "retry should have been cold")
local recovered = table.concat(vim.api.nvim_buf_get_lines(ui.answer_buf(), 0, -1, false), "\n")
assert(recovered:match("session expired"), "no sign of the recovery in the window")
assert(recovered:match("It takes `self` by value"), "the answer never arrived after retry")
print("stale-session recovery ok")
