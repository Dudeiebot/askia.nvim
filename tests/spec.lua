local ROOT = assert(os.getenv("ASKIA_ROOT"), "run me via tests/run.sh")
vim.opt.runtimepath:append(ROOT)
dofile(ROOT .. "/plugin/askia.lua")

local SP = ROOT .. "/tests"
local askia = require("askia")
local ui = require("askia.ui")

askia.setup({
  cmd = SP .. "/fake-claude",
  allowed_tools = { "Read", "Grep" },
  model = "sonnet",
})

-- allowed_tools must be replaced wholesale, not index-merged with the default.
assert(#require("askia.config").options.allowed_tools == 2, "allowed_tools leaked a default")

vim.cmd.edit(SP .. "/fixtures/greeter.lua")
vim.bo.filetype = "lua"

local done, err_out = false, nil
local orig_finish = ui.finish
ui.finish = function(e) orig_finish(e); done = true; err_out = e end

local function read_argv()
  local f = assert(io.open(assert(os.getenv("ASKIA_ARGV_LOG")), "rb"))
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
lines = run(function() askia.follow_up("and if it took &self?") end, "follow-up")
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
local c1, c2 = require("askia.context").enclosing_function(0)
assert(c1 == 3 and c2 == 6, ("c function range wrong: %s-%s"):format(c1, c2))
print("c enclosing_function: lines " .. c1 .. "-" .. c2)

-- 7. a snippet containing its own fence must not break out of the code block.
vim.cmd.enew()
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "```", "inner", "```" })
local p = require("askia.context").build_prompt(0, 1, 3, "q")
assert(p:match("````"), "fence not widened for backtick-containing code:\n" .. p)
print("fence widened ok")

print("\nALL ASSERTIONS PASSED")

-- 8. the promises the README makes to people installing this.
assert(vim.fn.exists(":Ask") == 2, ":Ask must exist without calling setup()")
assert(vim.fn.exists(":AskFollow") == 2 and vim.fn.exists(":AskCancel") == 2)
assert(vim.fn.maparg("<leader>aa", "n") == "", "a default mapping was claimed")
assert(vim.fn.maparg("<leader>aa", "x") == "", "a default mapping was claimed")

-- setup() with no arguments must not throw, and must leave defaults intact.
require("askia.config").setup()
assert(require("askia.config").options.cmd ~= nil)
print("public surface ok")

-- 9. sessions are reused per project root, so a later :Ask picks up what the
--    earlier one already learned.
local askia = require("askia")
askia.reset_session()
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
require("askia.config").setup({ session = "question" })
assert(not vim.tbl_contains(ask_again("Ask fourth", "session: per-question"), "--resume"),
  'session = "question" must never resume')

-- 12. a session past its ttl is abandoned rather than resumed.
require("askia.config").setup({ session = "project", session_ttl = 0.0001 }) -- ~6ms
ask_again("Ask fifth", "session: ttl warm-up")
vim.wait(50)
assert(not vim.tbl_contains(ask_again("Ask sixth", "session: ttl"), "--resume"),
  "an expired session must not be resumed")
require("askia.config").setup({ session_ttl = 30 })
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
require("askia.config").setup({ session = "project", session_ttl = 30 })
askia.reset_session()
ask_again("Ask warm up the session", "stale: warm-up")

local marker = vim.fn.tempname()
vim.fn.setenv("ASKIA_FAIL_RESUME", marker)
local argv_after = ask_again("Ask after the session went stale", "stale: recovery")
vim.fn.setenv("ASKIA_FAIL_RESUME", vim.NIL)

assert(vim.fn.filereadable(marker) == 1, "the stub never saw a --resume to reject")
assert(not vim.tbl_contains(argv_after, "--resume"), "retry should have been cold")
local recovered = table.concat(vim.api.nvim_buf_get_lines(ui.answer_buf(), 0, -1, false), "\n")
assert(recovered:match("session expired"), "no sign of the recovery in the window")
assert(recovered:match("It takes `self` by value"), "the answer never arrived after retry")
print("stale-session recovery ok")

-- 15. window geometry: fits the answer, resizes, maximizes, resets.
local function feed(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
end

require("askia.config").setup({ session = "question" }) -- keep these runs independent
ask_again("Ask a geometry question", "geometry")

local cols = vim.o.columns
local rows = vim.o.lines - vim.o.cmdheight - 1
local ceiling = math.floor(rows * 0.6)
local base_width = math.floor(cols * 0.55)

local d = ui.dimensions()
assert(d, "no window to measure")
assert(d.width == base_width, ("width %d, expected %d"):format(d.width, base_width))
assert(d.height >= 3 and d.height <= ceiling,
  ("height %d outside [3, %d]"):format(d.height, ceiling))
assert(d.height < rows, "auto-height should not fill the editor for a short answer")

feed("+")
assert(ui.dimensions().height == d.height + 2, "+ did not grow the window")
feed("-")
assert(ui.dimensions().height == d.height, "- did not undo the growth")
feed(">")
assert(ui.dimensions().width == d.width + 8, "> did not widen the window")
feed("<")
assert(ui.dimensions().width == d.width, "< did not narrow it back")

feed("M")
local maxed = ui.dimensions()
assert(maxed.width == cols - 2 and maxed.height == rows - 2,
  ("maximize gave %dx%d, expected %dx%d"):format(maxed.width, maxed.height, cols - 2, rows - 2))
feed("M")
assert(ui.dimensions().width == d.width, "maximize did not toggle back")

feed("+")
feed("=")
assert(ui.dimensions().width == base_width, "= did not restore the configured width")
assert(ui.dimensions().height <= ceiling, "= did not restore auto-height")
print("geometry ok")

-- 16. Q quits: window gone, answer discarded, nothing left to toggle back to.
local doomed = ui.answer_buf()
feed("Q")
assert(not ui.is_open(), "Q left the window open")
assert(not vim.api.nvim_buf_is_valid(doomed), "Q left the answer buffer behind")
assert(ui.toggle() == false, "Q should leave nothing to restore")

-- and quitting mid-flight kills the request instead of writing into a dead buffer.
ui.close()
vim.cmd.edit(SP .. "/fixtures/greeter.lua")
vim.bo.filetype = "lua"
vim.api.nvim_win_set_cursor(0, { 8, 0 })
done = false
local notices = {}
local real_notify = vim.notify
vim.notify = function(msg, lvl) table.insert(notices, msg); end
vim.cmd("Ask a question we will abandon")
assert(ui.is_open(), "window should be up while streaming")
require("askia").quit()
assert(vim.wait(10000, function() return done end, 30), "the abandoned job never exited")
assert(not ui.is_open() and ui.answer_buf() == nil, "quit left state behind")
vim.notify = real_notify
for _, msg in ipairs(notices) do
  assert(not msg:match("answer ready"),
    "quit still advertised an answer that was thrown away")
end
print("quit ok")

-- 17. the follow-up is typed inside the window, and the stream writes above it.
local function last_line(buf)
  local n = vim.api.nvim_buf_line_count(buf)
  return vim.api.nvim_buf_get_lines(buf, n - 1, n, false)[1] or ""
end

require("askia.config").setup({ session = "project" })
ui.close()
vim.cmd.edit(SP .. "/fixtures/greeter.lua")
vim.bo.filetype = "lua"
vim.api.nvim_win_set_cursor(0, { 8, 0 })

done = false
vim.cmd("Ask a question we will follow up on")
feed("<CR>") -- open the prompt while the answer is still streaming
local buf = ui.answer_buf()
assert(last_line(buf):match("^❯"), "no prompt line in the window")
assert(vim.bo[buf].modifiable, "the prompt line is not editable")

assert(vim.wait(15000, function() return done end, 30), "timed out mid-prompt")
assert(last_line(buf):match("^❯"), "the stream wrote over the prompt line")
local body = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
assert(body:match("It takes `self` by value"), "the answer did not land above the prompt")

-- Typing and sending it. `startinsert!` is deferred to the main loop, which a
-- headless feedkeys() never reaches, so the keys that enter insert, type, and
-- send have to go in as one batch.
done = false
feed("Awhat about &self?<CR>")
assert(vim.wait(15000, function() return done end, 30), "follow-up never completed")
local sent = read_argv()
assert(sent[2] == "what about &self?", "follow-up text wrong: " .. tostring(sent[2]))
assert(vim.tbl_contains(sent, "--resume"), "in-window follow-up did not resume the session")
assert(not last_line(ui.answer_buf()):match("^❯"), "prompt line left behind after sending")
assert(not vim.bo[ui.answer_buf()].modifiable, "buffer stayed editable after sending")
body = table.concat(vim.api.nvim_buf_get_lines(ui.answer_buf(), 0, -1, false), "\n")
assert(body:match("> what about &self%?"), "the follow-up is missing from the transcript")

-- <Esc> leaves insert but keeps what you typed; q then discards the prompt
-- rather than hiding the window.
feed("<CR>")
feed("Ahalf a question<Esc>")
assert(last_line(ui.answer_buf()):match("half a question"), "<Esc> threw the draft away")
feed("q")
assert(ui.is_open(), "q while prompting hid the whole window")
assert(not last_line(ui.answer_buf()):match("^❯"), "q did not discard the prompt")
feed("q")
assert(not ui.is_open(), "a second q should hide the window")
print("in-window follow-up ok")

-- 18. sessions are written to disk, and survive a restart of Neovim.
local store = require("askia.store")
require("askia.config").setup({ session = "project", session_ttl = 30, session_persist = true })
askia.reset_session()
ask_again("Ask something worth remembering", "store: write")

local root = vim.fs.root(0, { ".git" }) or vim.fn.getcwd()
local on_disk = store.read()
assert(on_disk[root], "nothing written for this project: " .. vim.inspect(on_disk))
assert(on_disk[root].id == "11111111-2222-3333-4444-555555555555", "wrong id stored")
assert(type(on_disk[root].used) == "number", "no timestamp stored")
assert(store.stat().bytes < 1024, "one project should not cost a kilobyte")

-- A fresh module is what a new Neovim gets: no in-memory table, only the file.
package.loaded["askia"] = nil
askia = require("askia")
askia.setup({ cmd = SP .. "/fake-claude", session = "project", session_ttl = 30 })
local after_restart = ask_again("Ask after a restart", "store: reload")
local at = vim.fn.index(after_restart, "--resume")
assert(at >= 0, "a restarted Neovim did not pick the session up from disk")
assert(after_restart[at + 2] == "11111111-2222-3333-4444-555555555555", "wrong id resumed")

-- 19. an entry past its ttl is neither resumed nor left in the file.
store.update(root, { id = "expired-session-id", used = store.now() - 3600 }, 0)
package.loaded["askia"] = nil
askia = require("askia")
askia.setup({ cmd = SP .. "/fake-claude", session = "project", session_ttl = 30 })
local after_expiry = ask_again("Ask with a stale entry on disk", "store: ttl")
assert(not vim.tbl_contains(after_expiry, "expired-session-id"), "resumed an expired session")
assert(store.read()[root].id ~= "expired-session-id", "expired entry left in the file")

-- 20. the file cannot grow without bound.
for i = 1, 60 do
  store.update("/tmp/project-" .. i, { id = "id-" .. i, used = store.now() + i }, 0)
end
local capped = store.read()
assert(vim.tbl_count(capped) == 50, "expected 50 entries, got " .. vim.tbl_count(capped))
assert(capped["/tmp/project-60"], "the most recent project was pruned")
assert(not capped["/tmp/project-1"], "the oldest project was kept")
assert(store.stat().bytes < 8192, "50 projects should still be a few KB")
print("session store ok")

-- 21. persistence can be turned off entirely.
os.remove(store.path())
package.loaded["askia"] = nil
askia = require("askia")
askia.setup({ cmd = SP .. "/fake-claude", session = "project", session_persist = false })
ask_again("Ask with persistence off", "store: opt out")
assert(vim.uv.fs_stat(store.path()) == nil, "session_persist = false still wrote a file")

-- 22. :AskInfo reports what is going on.
askia.setup({ session_persist = true })
ask_again("Ask before checking info", "store: info")

-- Called with the answer window focused, as it usually will be: it must still
-- report the project the question came from, not the scratch buffer's.
local info = table.concat(askia.info(), "\n")
assert(info:match("WDUDE/asking"), "info reported the wrong project:\n" .. info)
assert(info:match("root"), "no root in :AskInfo")
assert(info:match("11111111%-2222"), "no session id in :AskInfo:\n" .. info)
assert(info:match("ago"), "no age in :AskInfo")
assert(info:match("sessions%.json"), "no store path in :AskInfo")
print("AskInfo ok")

-- 23. handing the conversation to an interactive session.
askia.setup({ cmd = SP .. "/fake-claude", session = "project", model = "sonnet" })
askia.reset_session()

-- nothing to hand over yet
local warned_no_session = false
local plain_notify = vim.notify
vim.notify = function(msg) if msg:match("no session to hand over") then warned_no_session = true end end
local tabs_before = #vim.api.nvim_list_tabpages()
askia.escalate()
vim.notify = plain_notify
assert(warned_no_session, ":AskTerminal without a session should say so")
assert(#vim.api.nvim_list_tabpages() == tabs_before, "it opened a window with nothing to run")

ask_again("Ask before escalating", "terminal: session")
local id = "11111111-2222-3333-4444-555555555555"
assert(vim.deep_equal(askia.terminal_command(id), { SP .. "/fake-claude", "--resume", id, "--model", "sonnet" }),
  "wrong command: " .. vim.inspect(askia.terminal_command(id)))

local answer = ui.answer_buf()
askia.escalate()
assert(vim.bo[vim.api.nvim_get_current_buf()].buftype == "terminal", "no terminal was opened")
assert(#vim.api.nvim_list_tabpages() == tabs_before + 1, "the default is a new tab")
assert(not ui.is_open(), "the float should step aside")
assert(vim.api.nvim_buf_is_valid(answer), "escalating must not destroy the answer")
assert(ui.toggle(), "the answer should still be reachable with :AskToggle")
ui.close()

-- the other placements
vim.cmd("tabclose")
askia.setup({ terminal = { open = "vsplit" } })
local wins_before = #vim.api.nvim_tabpage_list_wins(0)
askia.escalate()
assert(vim.bo[vim.api.nvim_get_current_buf()].buftype == "terminal", "vsplit opened no terminal")
assert(#vim.api.nvim_tabpage_list_wins(0) == wins_before + 1, "vsplit did not split")
print("terminal escalation ok")

-- 24. how a project root is chosen, in the order it is chosen.
local tmp = vim.fn.tempname()
local function write(rel, text)
  local path = tmp .. "/" .. rel
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  vim.fn.writefile({ text or "x" }, path)
  return path
end

write("repo/.git/HEAD")                    -- a checkout ...
write("repo/packages/api/package.json")    -- ... with a manifest below it
local in_repo = write("repo/packages/api/main.js")

write("js/package.json")                   -- no vcs: a js project ...
write("js/crates/engine/Cargo.toml")       -- ... with a rust crate inside
local in_crate = write("js/crates/engine/lib.rs")

local loose = write("plain/deep/loose.txt") -- nothing project-shaped at all

-- On macOS tempname() hands back /var/..., while a resolved buffer path comes
-- out as /private/var/...; compare like for like.
tmp = vim.uv.fs_realpath(tmp) or tmp

local function root_of(path)
  ui.close()
  vim.cmd.edit(path)
  return askia.project_root(0)
end

assert(root_of(in_repo) == tmp .. "/repo",
  "a checkout should win over a manifest inside it, got " .. root_of(in_repo))
assert(root_of(in_crate) == tmp .. "/js/crates/engine",
  "the nearest manifest should win, not the first in the list, got " .. root_of(in_crate))
assert(root_of(loose) == tmp .. "/plain/deep",
  "an unmarked file should key on its own directory, got " .. root_of(loose))

-- A nameless buffer has no path to walk up from, so vim.fs.root() starts at the
-- current directory: inside a checkout that still resolves to the repo, and
-- only somewhere unmarked does it come back as the cwd itself.
ui.close()
vim.cmd("enew")
assert(askia.project_root(0) == ROOT,
  "a nameless buffer inside a repo should key on the repo, got " .. askia.project_root(0))

vim.cmd("cd " .. tmp .. "/plain/deep")
assert(askia.project_root(0) == tmp .. "/plain/deep",
  "with nothing above the cwd it should key on the cwd, got " .. askia.project_root(0))
vim.cmd("cd " .. ROOT .. "/tests")
vim.fn.delete(tmp, "rf")
print("root resolution ok")

-- 25. references: mark functions in other files, send them with the question.
local refs = require("askia.refs")
askia.setup({ cmd = SP .. "/fake-claude", session = "question" })
refs.clear()
ui.close()

-- mark a function in one file ...
vim.cmd.edit(SP .. "/fixtures/greet.c")
vim.bo.filetype = "c"
vim.cmd("3,6AskAdd")
assert(refs.count() == 1, "the c function was not attached")

-- ... and a second one elsewhere
vim.cmd.edit(SP .. "/fixtures/greeter.lua")
vim.bo.filetype = "lua"
vim.cmd("3,5AskAdd")
assert(refs.count() == 2, "the lua function was not attached")

-- marking the same lines again refreshes rather than duplicates
vim.cmd("3,5AskAdd")
assert(refs.count() == 2, "duplicate reference was stacked")

-- now ask about something else entirely
vim.api.nvim_win_set_cursor(0, { 8, 0 })
run(function() vim.cmd("Ask why does this drop the shout?") end, "refs: ask")
local prompt = read_argv()[2]

local ref_c = prompt:find("Reference: fixtures/greet%.c %(lines 3%-6%)")
local ref_lua = prompt:find("Reference: fixtures/greeter%.lua %(lines 3%-5%)")
local subject = prompt:find("File: fixtures/greeter%.lua %(lines 7%-11%)")
assert(ref_c and ref_lua and subject, "missing blocks in the prompt:\n" .. prompt)
assert(ref_c < subject and ref_lua < subject, "references must come before the subject")
assert(prompt:find("int add%(int a, int b%)"), "the c reference carried no code")
assert(prompt:find("```c"), "the c reference lost its filetype")
assert(prompt:match("why does this drop the shout%?$"), "the question must come last")

-- 26. an edit above a reference moves it: the marked lines are still sent.
ui.hide() -- the answer window has focus and is winfixbuf'd
vim.cmd.edit(SP .. "/fixtures/greeter.lua")
vim.api.nvim_buf_set_lines(0, 0, 0, false, { "-- a new line at the top", "-- and another" })
vim.api.nvim_win_set_cursor(0, { 10, 0 })
run(function() vim.cmd("Ask and now?") end, "refs: after an edit")
prompt = read_argv()[2]
assert(prompt:find("Reference: fixtures/greeter%.lua %(lines 5%-7%)"),
  "the reference did not follow the edit:\n" .. prompt)
assert(prompt:find("return s:upper%(%) .. \"!\""), "the moved reference sent the wrong lines")
ui.hide() -- again: :edit! cannot run with the float focused
vim.cmd("silent! edit!") -- drop the scratch edit

-- 27. references survive across questions, and :AskClear drops them.
assert(refs.count() == 2, "references should outlive a question")
local info = table.concat(askia.info(), "\n")
assert(info:match("refs      2 attached"), ":AskInfo does not mention references:\n" .. info)
vim.cmd("AskClear")
assert(refs.count() == 0, ":AskClear left references behind")

ui.close()
vim.cmd.edit(SP .. "/fixtures/greeter.lua")
vim.bo.filetype = "lua"
vim.api.nvim_win_set_cursor(0, { 8, 0 })
run(function() vim.cmd("Ask with nothing attached") end, "refs: cleared")
assert(not read_argv()[2]:find("Reference:"), "a cleared reference was still sent")
print("references ok")

-- 28. the subject is not also sent as a reference.
refs.clear()
ui.close()
vim.cmd.edit(SP .. "/fixtures/greeter.lua")
vim.bo.filetype = "lua"
vim.api.nvim_win_set_cursor(0, { 8, 0 })
vim.cmd("AskAdd")                      -- mark the function we are about to ask about
vim.cmd("3,5AskAdd")                   -- and one we are not
assert(refs.count() == 2, "expected both marks")

run(function() vim.cmd("Ask what does this do?") end, "refs: subject overlap")
local dup = read_argv()[2]
local _, references_sent = dup:gsub("Reference:", "")
assert(references_sent == 1, "expected 1 reference block, got " .. references_sent .. ":\n" .. dup)
assert(dup:find("Reference: fixtures/greeter%.lua %(lines 3%-5%)"), "the unrelated mark was dropped")
assert(not dup:find("Reference: fixtures/greeter%.lua %(lines 7%-11%)"), "the subject was sent twice")
local _, subjects = dup:gsub("File:", "")
assert(subjects == 1, "expected exactly one subject block")
refs.clear()
print("subject/reference overlap ok")

-- 29. references change the instructions, and only when there are any.
refs.clear()
ui.close()
vim.cmd.edit(SP .. "/fixtures/greeter.lua")
vim.bo.filetype = "lua"
vim.api.nvim_win_set_cursor(0, { 8, 0 })

run(function() vim.cmd("Ask") end, "prompt: no references")
local bare = read_argv()
local sp = bare[vim.fn.index(bare, "--append-system-prompt") + 2]
assert(not sp:find("Reference blocks"), "the reference instructions leaked into a plain question")
assert(bare[2]:match("Explain what this does and why%.$"), "wrong default question")

ui.hide() -- back to the code buffer; :AskAdd refuses to run from the answer window
run(function()
  vim.cmd("3,5AskAdd")
  vim.cmd("Ask")
end, "prompt: with references")
local with = read_argv()
sp = with[vim.fn.index(with, "--append-system-prompt") + 2]
assert(sp:find("Reference blocks"), "references were sent without instructions for them")
assert(sp:find("never stop and wait to be asked to continue"), "no instruction to answer in one reply")
assert(with[2]:match("how each attached reference relates to it%.$"),
  "the default question ignored the references; tail was:\n" .. with[2]:sub(-90))
assert(with[2]:find("Attached for this question, 1 reference from elsewhere"),
  "no lead-in introducing the references:\n" .. with[2])
refs.clear()
print("reference instructions ok")

-- 30. edit_question: :Ask with no question opens the prompt pre-filled.
local ARGV = assert(os.getenv("ASKIA_ARGV_LOG"))
local function poison_argv()
  local f = assert(io.open(ARGV, "w"))
  f:write("NOTHING-WAS-SENT\0")
  f:close()
end
local function nothing_sent()
  return read_argv()[1] == "NOTHING-WAS-SENT"
end

refs.clear()
askia.setup({ cmd = SP .. "/fake-claude", session = "question", edit_question = true })
ui.close()
vim.cmd.edit(SP .. "/fixtures/greeter.lua")
vim.bo.filetype = "lua"
vim.api.nvim_win_set_cursor(0, { 8, 0 })

poison_argv()
vim.cmd("Ask")
assert(ui.is_open(), "compose did not open a window")
assert(nothing_sent(), ":Ask fired a request before the question was submitted")
local draft = last_line(ui.answer_buf())
assert(draft == "❯ Explain what this does and why.",
  "the prompt was not pre-filled with the default: " .. draft)
assert(vim.bo[ui.answer_buf()].modifiable, "the draft is not editable")

-- editing it, then sending
done = false
feed("A and mention the return value<CR>")
assert(vim.wait(15000, function() return done end, 30), "the composed question never went out")
local composed = read_argv()
assert(composed[2]:match("Explain what this does and why%. and mention the return value$"),
  "the edit was not sent: " .. composed[2]:sub(-70))
local shown = table.concat(vim.api.nvim_buf_get_lines(ui.answer_buf(), 0, -1, false), "\n")
assert(shown:match("^> Explain what this does and why%. and mention the return value"),
  "the composed question is missing from the transcript")

-- and the same prompt line now serves follow-ups
done = false
feed("<CR>")
feed("Aa follow up<CR>")
assert(vim.wait(15000, function() return done end, 30), "the follow-up never went out")
local followed = read_argv()
assert(followed[2] == "a follow up", "follow-up sent the wrong text: " .. tostring(followed[2]))
assert(vim.tbl_contains(followed, "--resume"), "the follow-up did not resume")
print("edit_question ok")

-- 31. backing out of a composed question sends nothing and closes the window.
ui.close()
vim.cmd.edit(SP .. "/fixtures/greeter.lua")
vim.bo.filetype = "lua"
vim.api.nvim_win_set_cursor(0, { 8, 0 })
poison_argv()
vim.cmd("Ask")
assert(ui.is_open(), "compose did not open")
feed("q")
assert(not ui.is_open(), "q left the compose window open")
assert(ui.answer_buf() == nil, "q left an empty answer buffer behind")
assert(nothing_sent(), "backing out still sent a question")

-- a typed question ignores the flag and goes straight out
run(function() vim.cmd("Ask straight to the point") end, "edit_question: typed")
assert(read_argv()[2]:match("straight to the point$"), "a typed question was not sent as-is")

-- with references attached, the draft is the references-aware default
ui.hide()
run(function()
  vim.cmd("3,5AskAdd")
  vim.cmd("Ask what is this")
end, "edit_question: refs draft setup")
ui.hide()
vim.api.nvim_win_set_cursor(0, { 8, 0 })
poison_argv()
vim.cmd("Ask")
assert(last_line(ui.answer_buf()):match("how each attached reference relates to it%.$"),
  "the pre-filled draft ignored the references: " .. last_line(ui.answer_buf()))
feed("q")
refs.clear()
askia.setup({ edit_question = false })
print("compose cancel ok")

-- 32. every option is documented. Adding a config key without saying so in the
--     README is the easiest kind of rot to ship.
local readme = assert(io.open(ROOT .. "/README.md")):read("*a")
local helpdoc = assert(io.open(ROOT .. "/doc/askia.txt")):read("*a")

local function documented(name, text)
  return text:find(name, 1, true) ~= nil
end

local undocumented = {}
for key, value in pairs(require("askia.config").options) do
  local names = { key }
  if type(value) == "table" and not vim.islist(value) then
    names = {}
    for sub in pairs(value) do
      table.insert(names, key .. "." .. sub)
    end
    if #names == 0 then names = { key } end -- keymaps, empty by default
  end
  for _, name in ipairs(names) do
    if not documented(name, readme) then
      table.insert(undocumented, name .. " (README)")
    end
  end
  if not documented(key, helpdoc) then
    table.insert(undocumented, key .. " (:help)")
  end
end

assert(#undocumented == 0, "undocumented options: " .. table.concat(undocumented, ", "))

-- and every command the plugin defines
for _, cmd in ipairs({
  "Ask", "AskAdd", "AskClear", "AskFollow", "AskCancel",
  "AskToggle", "AskClose", "AskTerminal", "AskInfo", "AskReset",
}) do
  assert(vim.fn.exists(":" .. cmd) == 2, cmd .. " is not defined")
  assert(documented(":" .. cmd, readme), cmd .. " is missing from the README")
  assert(documented("*:" .. cmd .. "*", helpdoc), cmd .. " has no help tag")
end
print("documentation ok")
