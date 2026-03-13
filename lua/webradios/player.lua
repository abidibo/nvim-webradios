-- lua/webradios/player.lua
local config = require("webradios.config")

local M = {}

local state = {
  job_id = nil,
  ipc_socket = nil,
  station = nil,
  paused = false,
  volume = nil,
}

local function get_socket_path()
  return string.format("/tmp/nvim-webradios-%d.sock", vim.fn.getpid())
end

local function cleanup_socket()
  local path = get_socket_path()
  vim.fn.delete(path)
end

local function send_ipc(command_table)
  local socket_path = state.ipc_socket
  if not socket_path then
    return
  end

  local json = vim.json.encode({ command = command_table }) .. "\n"

  local pipe = vim.uv.new_pipe(false)
  pipe:connect(socket_path, function(err)
    if err then
      pipe:close()
      return
    end
    pipe:write(json, function()
      pipe:close()
    end)
  end)
end

function M.play(station)
  -- Stop current playback if any
  M.stop()

  if not vim.fn.executable(config.options.player) then
    vim.notify(
      config.options.player .. " not found. Install it to play stations.",
      vim.log.levels.ERROR
    )
    return
  end

  state.volume = state.volume or config.options.volume
  state.ipc_socket = get_socket_path()
  state.station = station
  state.paused = false

  state.job_id = vim.fn.jobstart({
    config.options.player,
    "--no-video",
    "--terminal=no",
    "--volume=" .. tostring(state.volume),
    "--input-ipc-server=" .. state.ipc_socket,
    station.url_resolved,
  }, {
    on_exit = function(_, exit_code)
      vim.schedule(function()
        state.job_id = nil
        state.station = nil
        state.paused = false
        cleanup_socket()
        -- Notify UI if it has a registered callback
        if M._on_state_change then
          M._on_state_change()
        end
      end)
    end,
  })
end

function M.stop()
  if state.job_id then
    pcall(vim.fn.jobstop, state.job_id)
    state.job_id = nil
  end
  state.station = nil
  state.paused = false
  cleanup_socket()
  if M._on_state_change then
    pcall(M._on_state_change)
  end
end

function M.toggle_pause()
  if not state.job_id or not state.ipc_socket then
    return
  end
  send_ipc({ "cycle", "pause" })
  state.paused = not state.paused
  if M._on_state_change then
    M._on_state_change()
  end
end

function M.volume_up()
  if not state.job_id or not state.ipc_socket then
    return
  end
  state.volume = math.min(100, (state.volume or config.options.volume) + config.options.volume_step)
  send_ipc({ "set", "volume", state.volume })
  if M._on_state_change then
    M._on_state_change()
  end
end

function M.volume_down()
  if not state.job_id or not state.ipc_socket then
    return
  end
  state.volume = math.max(0, (state.volume or config.options.volume) - config.options.volume_step)
  send_ipc({ "set", "volume", state.volume })
  if M._on_state_change then
    M._on_state_change()
  end
end

function M.get_state()
  return {
    playing = state.job_id ~= nil,
    station = state.station,
    paused = state.paused,
    volume = state.volume or config.options.volume,
  }
end

-- Callback hook for UI updates (set by ui.lua)
M._on_state_change = nil

-- Cleanup on Neovim exit
vim.api.nvim_create_autocmd("VimLeavePre", {
  callback = function()
    M.stop()
  end,
})

return M
