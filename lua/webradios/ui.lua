-- lua/webradios/ui.lua
local api = require("webradios.api")
local player = require("webradios.player")

local M = {}

local placeholder_ns = vim.api.nvim_create_namespace("webradios_placeholder")

local ui_state = {
  buf = nil,
  win = nil,
  stations = {},
}

local function is_open()
  return ui_state.win
    and vim.api.nvim_win_is_valid(ui_state.win)
    and ui_state.buf
    and vim.api.nvim_buf_is_valid(ui_state.buf)
end

local function get_dimensions()
  local width = math.ceil(vim.o.columns * 0.7)
  local height = math.ceil(vim.o.lines * 0.6)
  local row = math.ceil((vim.o.lines - height) / 2)
  local col = math.ceil((vim.o.columns - width) / 2)
  return { width = width, height = height, row = row, col = col }
end

local function render_search_placeholder()
  if not is_open() then
    return
  end
  local line = vim.api.nvim_buf_get_lines(ui_state.buf, 0, 1, false)[1] or ""
  local content = line:gsub("^>%s*", ""):gsub("%s+$", "")
  vim.api.nvim_buf_clear_namespace(ui_state.buf, placeholder_ns, 0, 1)
  if content == "" then
    vim.api.nvim_buf_set_extmark(ui_state.buf, placeholder_ns, 0, 3, {
      virt_text = { { "Search station...", "Comment" } },
      virt_text_pos = "inline",
    })
  end
end

local HELP_LINES = {
  "  <CR>  Play / Search     /     New search",
  "  p     Pause / Resume    s     Stop",
  "  +     Volume up         -     Volume down",
  "  q     Close             <Esc> Close",
}

-- Forward declarations
local render_help
local render_status_bar
local set_keybindings
local render_results

render_help = function()
  if not is_open() then
    return
  end

  local dim = get_dimensions()
  local separator = string.rep("─", dim.width)
  local was_modifiable = vim.bo[ui_state.buf].modifiable
  vim.bo[ui_state.buf].modifiable = true
  local lines = { separator }
  for _, line in ipairs(HELP_LINES) do
    table.insert(lines, line)
  end
  local line_count = vim.api.nvim_buf_line_count(ui_state.buf)
  vim.api.nvim_buf_set_lines(ui_state.buf, line_count, line_count, false, lines)
  vim.bo[ui_state.buf].modifiable = was_modifiable
end

render_status_bar = function()
  if not is_open() then
    return
  end

  local pstate = player.get_state()
  local status

  if pstate.playing and pstate.station then
    local icon = pstate.paused and "⏸ " or "▶ "
    local bitrate = ""
    if pstate.station.bitrate and pstate.station.bitrate > 0 then
      bitrate = " — " .. pstate.station.bitrate .. " kbps"
    end
    status = icon .. pstate.station.name .. bitrate .. " | Vol: " .. pstate.volume .. "%"
  else
    status = "⏹ Stopped"
  end

  -- status line sits above the fixed help block (help separator + HELP_LINES)
  local line_count = vim.api.nvim_buf_line_count(ui_state.buf)
  local status_idx = line_count - #HELP_LINES - 2
  local was_modifiable = vim.bo[ui_state.buf].modifiable
  vim.bo[ui_state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(ui_state.buf, status_idx, status_idx + 1, false, { " " .. status })
  vim.bo[ui_state.buf].modifiable = was_modifiable
end

local function play_selected()
  if not is_open() then
    return
  end

  local cursor = vim.api.nvim_win_get_cursor(ui_state.win)
  local row = cursor[1]

  local station_index = row - 2
  if station_index < 1 or station_index > #ui_state.stations then
    return
  end

  local station = ui_state.stations[station_index]
  player.play(station)
  api.register_click(station.stationuuid)
  render_status_bar()
end

local function new_search()
  if not is_open() then
    return
  end

  ui_state.stations = {}

  vim.bo[ui_state.buf].modifiable = true

  local dim = get_dimensions()
  local separator = string.rep("─", dim.width)
  vim.api.nvim_buf_set_lines(ui_state.buf, 0, -1, false, {
    ">  ",
    separator,
    "",
    separator,
    "",
  })

  render_help()
  render_status_bar()
  render_search_placeholder()

  -- Ensure buffer stays modifiable for insert mode on search line
  vim.bo[ui_state.buf].modifiable = true
  vim.api.nvim_win_set_cursor(ui_state.win, { 1, 3 })
  vim.cmd("startinsert")
end

local function trigger_search()
  if not is_open() then
    return
  end

  local search_line = vim.api.nvim_buf_get_lines(ui_state.buf, 0, 1, false)[1] or ""
  local keyword = search_line:gsub("^>%s*", ""):gsub("%s+$", "")

  if keyword == "" then
    return
  end

  vim.bo[ui_state.buf].modifiable = true
  local dim = get_dimensions()
  local separator = string.rep("─", dim.width)
  vim.api.nvim_buf_set_lines(ui_state.buf, 2, -1, false, {
    "  searching...",
    separator,
    "",
  })
  render_help()
  render_status_bar()
  vim.bo[ui_state.buf].modifiable = false

  vim.cmd("stopinsert")

  local search_keyword = keyword
  api.search(keyword, function(stations, err)
    if not err and stations and #stations == 0 then
      render_results(stations, "No stations found for '" .. search_keyword .. "'")
    else
      render_results(stations, err)
    end
  end)
end

render_results = function(stations, error_msg)
  if not is_open() then
    return
  end

  local dim = get_dimensions()
  ui_state.stations = stations or {}

  vim.bo[ui_state.buf].modifiable = true

  local lines = {}

  if error_msg then
    table.insert(lines, "  " .. error_msg)
  elseif #ui_state.stations == 0 then
    table.insert(lines, "  No stations found")
  else
    local name_w = math.max(20, math.floor(dim.width * 0.4))
    local country_w = 4
    local tags_w = math.max(10, math.floor(dim.width * 0.25))

    for _, s in ipairs(ui_state.stations) do
      local name = s.name
      if vim.fn.strchars(name) > name_w then
        name = vim.fn.strcharpart(name, 0, name_w - 1) .. "…"
      end

      local tags = s.tags
      if vim.fn.strchars(tags) > tags_w then
        tags = vim.fn.strcharpart(tags, 0, tags_w - 1) .. "…"
      end

      local bitrate = s.bitrate > 0 and (tostring(s.bitrate) .. " kbps") or ""

      local line = string.format(
        "  %-" .. name_w .. "s %-" .. country_w .. "s %-" .. tags_w .. "s %s",
        name,
        s.country,
        tags,
        bitrate
      )
      table.insert(lines, line)
    end
  end

  local separator = string.rep("─", dim.width)
  table.insert(lines, separator)
  table.insert(lines, "")

  vim.api.nvim_buf_set_lines(ui_state.buf, 2, -1, false, lines)
  render_help()
  vim.bo[ui_state.buf].modifiable = false

  render_status_bar()

  if ui_state.stations and #ui_state.stations > 0 then
    vim.api.nvim_win_set_cursor(ui_state.win, { 3, 0 })
  end
end

set_keybindings = function()
  local buf = ui_state.buf
  local opts = { buffer = buf, noremap = true, silent = true, nowait = true }

  vim.keymap.set("n", "<CR>", function()
    local row = vim.api.nvim_win_get_cursor(ui_state.win)[1]
    if row == 1 then
      trigger_search()
    else
      play_selected()
    end
  end, opts)

  vim.keymap.set("i", "<CR>", function()
    trigger_search()
  end, opts)

  vim.keymap.set("n", "/", function()
    new_search()
  end, opts)

  vim.keymap.set("n", "p", function()
    player.toggle_pause()
  end, opts)

  vim.keymap.set("n", "s", function()
    player.stop()
  end, opts)

  vim.keymap.set("n", "+", function()
    player.volume_up()
  end, opts)

  vim.keymap.set("n", "-", function()
    player.volume_down()
  end, opts)

  vim.keymap.set("n", "q", function()
    M.close()
  end, opts)
  vim.keymap.set("n", "<Esc>", function()
    M.close()
  end, opts)
end

function M.open()
  if is_open() then
    vim.api.nvim_set_current_win(ui_state.win)
    return
  end

  local dim = get_dimensions()

  ui_state.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[ui_state.buf].buftype = "nofile"
  vim.bo[ui_state.buf].bufhidden = "wipe"
  vim.bo[ui_state.buf].swapfile = false

  ui_state.win = vim.api.nvim_open_win(ui_state.buf, true, {
    relative = "editor",
    width = dim.width,
    height = dim.height,
    row = dim.row,
    col = dim.col,
    style = "minimal",
    border = "rounded",
    title = " Web Radios ",
    title_pos = "center",
  })

  vim.bo[ui_state.buf].modifiable = true
  local separator = string.rep("─", dim.width)
  vim.api.nvim_buf_set_lines(ui_state.buf, 0, -1, false, {
    ">  ",
    separator,
    "",
    separator,
    "",
  })

  set_keybindings()
  render_help()
  render_status_bar()
  render_search_placeholder()

  -- Ensure buffer stays modifiable for insert mode on search line
  vim.bo[ui_state.buf].modifiable = true

  player._on_state_change = function()
    if is_open() then
      render_status_bar()
    end
  end

  vim.api.nvim_create_autocmd({ "TextChangedI", "TextChanged" }, {
    buffer = ui_state.buf,
    callback = render_search_placeholder,
  })

  -- Redirect any insert mode attempt to the search line
  vim.api.nvim_create_autocmd("InsertEnter", {
    buffer = ui_state.buf,
    callback = function()
      local row = vim.api.nvim_win_get_cursor(ui_state.win)[1]
      if row ~= 1 then
        vim.bo[ui_state.buf].modifiable = true
        vim.api.nvim_win_set_cursor(ui_state.win, { 1, 3 })
      end
    end,
  })

  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = ui_state.buf,
    once = true,
    callback = function()
      ui_state.buf = nil
      ui_state.win = nil
      ui_state.stations = {}
    end,
  })

  vim.api.nvim_win_set_cursor(ui_state.win, { 1, 3 })
  vim.cmd("startinsert")
end

function M.close()
  if is_open() then
    vim.api.nvim_win_close(ui_state.win, true)
  end
end

return M
