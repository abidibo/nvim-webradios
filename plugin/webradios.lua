if vim.g.loaded_webradios then
  return
end
vim.g.loaded_webradios = true

vim.api.nvim_create_user_command("Webradios", function()
  require("webradios").open()
end, { desc = "Open web radios browser" })

vim.keymap.set("n", "<Plug>(webradios-open)", function()
  require("webradios").open()
end, { desc = "Open web radios browser" })
