if vim.g.loaded_asking then return end
vim.g.loaded_asking = true

if vim.fn.has("nvim-0.10") == 0 then
  vim.notify("asking.nvim requires neovim 0.10+ (vim.system, vim.uv)", vim.log.levels.ERROR)
  return
end

vim.api.nvim_create_user_command("Ask", function(opts)
  -- line1/line2 are populated even without a range, so range==0 is the only
  -- way to tell "no selection" from "one line selected".
  local l1, l2
  if opts.range > 0 then
    l1, l2 = opts.line1, opts.line2
  end
  require("asking").ask({ line1 = l1, line2 = l2, question = opts.args })
end, {
  range = true,
  nargs = "?",
  desc = "Ask Claude about the selection, or the function under the cursor",
})

vim.api.nvim_create_user_command("AskFollow", function(opts)
  require("asking").follow_up(opts.args)
end, { nargs = "+", desc = "Continue the current Claude conversation" })

vim.api.nvim_create_user_command("AskCancel", function()
  require("asking").cancel()
end, { desc = "Cancel the in-flight Claude request" })
