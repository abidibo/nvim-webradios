-- lua/webradios/init.lua
local M = {}

function M.setup(opts)
  require("webradios.config").setup(opts)
end

function M.open()
  require("webradios.ui").open()
end

function M.status()
  local player = require("webradios.player")
  local pstate = player.get_state()

  if pstate.playing and pstate.station then
    local icon = pstate.paused and "⏸ " or "▶ "
    local bitrate = ""
    if pstate.station.bitrate and pstate.station.bitrate > 0 then
      bitrate = " — " .. pstate.station.bitrate .. " kbps"
    end
    return icon .. pstate.station.name .. bitrate
  end

  return ""
end

return M
