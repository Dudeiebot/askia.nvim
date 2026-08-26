if vim.g.loaded_askia then return end
vim.g.loaded_askia = true

if vim.fn.has("nvim-0.10") == 0 then
  vim.notify("askia requires neovim 0.10+ (vim.system, vim.uv)", vim.log.levels.ERROR)
  return
end

vim.api.nvim_create_user_command("Ask", function(opts)
  -- line1/line2 are populated even without a range, so range==0 is the only
  -- way to tell "no selection" from "one line selected".
  local l1, l2
  if opts.range > 0 then
    l1, l2 = opts.line1, opts.line2
  end
  require("askia").ask({
    line1 = l1,
    line2 = l2,
    question = opts.args,
    fresh = opts.bang, -- :Ask! ignores the project's session
  })
end, {
  range = true,
  nargs = "?",
  bang = true,
  desc = "Ask Claude about the selection, or the function under the cursor",
})

vim.api.nvim_create_user_command(
  "AskToggle",
  function() require("askia").toggle() end,
  { desc = "Hide the Claude answer window, or bring the last one back" }
)

vim.api.nvim_create_user_command(
  "AskClose",
  function() require("askia").quit() end,
  { desc = "Close the Claude answer window and discard the answer" }
)

vim.api.nvim_create_user_command(
  "AskTerminal",
  function() require("askia").escalate() end,
  { desc = "Continue this project's Claude session in an interactive terminal" }
)

vim.api.nvim_create_user_command(
  "AskInfo",
  function() require("askia").info() end,
  { desc = "Show this project's Claude session and where it is stored" }
)

vim.api.nvim_create_user_command(
  "AskReset",
  function() require("askia").reset_session() end,
  { desc = "Forget this project's Claude session" }
)

vim.api.nvim_create_user_command("AskAdd", function(opts)
  local l1, l2
  if opts.range > 0 then
    l1, l2 = opts.line1, opts.line2
  end
  require("askia").add_reference({ line1 = l1, line2 = l2 })
end, {
  range = true,
  desc = "Attach this function, or the selection, to the next question",
})

vim.api.nvim_create_user_command(
  "AskClear",
  function() require("askia").clear_references() end,
  { desc = "Drop every attached reference" }
)

vim.api.nvim_create_user_command(
  "AskFollow",
  function(opts) require("askia").follow_up(opts.args) end,
  { nargs = "+", desc = "Continue the current Claude conversation" }
)

vim.api.nvim_create_user_command(
  "AskCancel",
  function() require("askia").cancel() end,
  { desc = "Cancel the in-flight Claude request" }
)
