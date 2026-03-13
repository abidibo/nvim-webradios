-- lua/webradios/config.lua
local M = {}

M.defaults = {
  api_url = "https://all.api.radio-browser.info",
  limit = 30,
  player = "mpv",
  volume = 80,
  volume_step = 5,
}

M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", {}, M.defaults, opts or {})
end

return M
