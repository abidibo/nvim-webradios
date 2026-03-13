# nvim-webradios Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a Neovim plugin that lets users search and play internet radio stations from a floating overlay, using radio-browser.info API and mpv.

**Architecture:** Six Lua modules with clear boundaries — config (defaults), api (async HTTP), player (mpv IPC), ui (floating window), init (public API glue), and a plugin entry point. Each module is a standalone file returning a table of functions.

**Tech Stack:** Lua, Neovim API (>=0.9), mpv (external), curl (external), radio-browser.info REST API

**Spec:** `docs/superpowers/specs/2026-03-13-nvim-webradios-design.md`

---

## File Structure

| File | Responsibility |
|------|---------------|
| `lua/webradios/config.lua` | Default config, merge with user opts |
| `lua/webradios/api.lua` | Async curl to radio-browser.info, search + click tracking |
| `lua/webradios/player.lua` | mpv process lifecycle, IPC socket for pause/volume |
| `lua/webradios/ui.lua` | Floating window, search input, results rendering, keybindings, status bar |
| `lua/webradios/init.lua` | Public API: `setup()`, `open()`, `status()`, glue between modules |
| `plugin/webradios.lua` | `:Webradios` command, `<Plug>(webradios-open)` mapping |

---

## Chunk 1: Foundation (config, api, player)

### Task 1: Config module

**Files:**
- Create: `lua/webradios/config.lua`

- [ ] **Step 1: Create config module with defaults**

```lua
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
```

- [ ] **Step 2: Verify config module loads**

Open Neovim from the project root and run:
```
nvim --cmd "set rtp+=." -c "lua print(vim.inspect(require('webradios.config').options))"
```
Expected: prints the default config table with `api_url`, `limit`, `player`, `volume`, `volume_step`.

- [ ] **Step 3: Verify setup merges options**

```
nvim --cmd "set rtp+=." -c "lua local c = require('webradios.config'); c.setup({volume = 50}); print(c.options.volume, c.options.limit)"
```
Expected: prints `50	30` (volume overridden, limit kept default).

- [ ] **Step 4: Commit**

```bash
git add lua/webradios/config.lua
git commit -m "feat: add config module with defaults and setup merge"
```

---

### Task 2: API module

**Files:**
- Create: `lua/webradios/api.lua`

- [ ] **Step 1: Create api module with search function**

```lua
-- lua/webradios/api.lua
local config = require("webradios.config")

local M = {}

M._search_job_id = nil

function M.search(keyword, callback)
  -- Cancel any in-flight search
  if M._search_job_id then
    pcall(vim.fn.jobstop, M._search_job_id)
    M._search_job_id = nil
  end

  local url = string.format(
    "%s/json/stations/search?name=%s&limit=%d&hidebroken=true&order=votes&reverse=true",
    config.options.api_url,
    vim.uri_encode(keyword),
    config.options.limit
  )

  local stdout_data = {}

  M._search_job_id = vim.fn.jobstart({
    "curl", "-s",
    "-H", "User-Agent: nvim-webradios",
    url,
  }, {
    stdout_buffered = true,
    on_stdout = function(_, data)
      stdout_data = data
    end,
    on_exit = function(_, exit_code)
      M._search_job_id = nil
      vim.schedule(function()
        if exit_code ~= 0 then
          callback(nil, "Error: could not reach radio-browser API")
          return
        end

        -- stdout_buffered delivers all data at once; last element is empty string
        local raw = table.concat(stdout_data, "")
        if raw == "" then
          callback(nil, "Error: empty response from API")
          return
        end

        local ok, decoded = pcall(vim.json.decode, raw)
        if not ok or type(decoded) ~= "table" then
          callback(nil, "Error: could not parse API response")
          return
        end

        local stations = {}
        for _, s in ipairs(decoded) do
          table.insert(stations, {
            stationuuid = s.stationuuid or "",
            name = s.name or "Unknown",
            url_resolved = s.url_resolved or s.url or "",
            country = s.countrycode or "",
            tags = s.tags or "",
            bitrate = s.bitrate or 0,
            codec = s.codec or "",
          })
        end

        callback(stations)
      end)
    end,
  })
end

function M.register_click(stationuuid)
  if not stationuuid or stationuuid == "" then
    return
  end

  local url = string.format(
    "%s/json/url/%s",
    config.options.api_url,
    stationuuid
  )

  vim.fn.jobstart({
    "curl", "-s",
    "-H", "User-Agent: nvim-webradios",
    url,
  }, {
    on_exit = function() end, -- fire and forget
  })
end

return M
```

- [ ] **Step 2: Verify search returns results**

```
nvim --cmd "set rtp+=." -c "lua require('webradios.api').search('jazz', function(stations, err) if err then print(err) else print(#stations .. ' stations found; first: ' .. stations[1].name) end end)"
```
Expected: prints something like `30 stations found; first: Jazz FM` (actual names vary). Wait a moment for the async callback.

- [ ] **Step 3: Verify error handling with bad URL**

```
nvim --cmd "set rtp+=." -c "lua require('webradios.config').setup({api_url='https://invalid.example.com'}); require('webradios.api').search('jazz', function(s, err) print(err or 'unexpected success') end)"
```
Expected: prints an error message after curl fails.

- [ ] **Step 4: Commit**

```bash
git add lua/webradios/api.lua
git commit -m "feat: add async API module with search and click tracking"
```

---

### Task 3: Player module

**Files:**
- Create: `lua/webradios/player.lua`

- [ ] **Step 1: Create player module with state and play/stop**

```lua
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
    M._on_state_change()
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
```

- [ ] **Step 2: Verify player module loads without errors**

```
nvim --cmd "set rtp+=." -c "lua local p = require('webradios.player'); print(vim.inspect(p.get_state()))"
```
Expected: prints `{ paused = false, playing = false, volume = 80 }` (no station, not playing).

- [ ] **Step 3: Verify play and stop work with mpv**

Requires mpv installed. Run:
```
nvim --cmd "set rtp+=." -c "lua local p = require('webradios.player'); p.play({name='Test', url_resolved='https://stream.live.vc.bbcmedia.co.uk/bbc_radio_three', bitrate=320}); vim.defer_fn(function() print(vim.inspect(p.get_state())) end, 2000)"
```
Expected: after 2 seconds prints state with `playing = true`, `station.name = "Test"`. You should hear audio. Then `:lua require('webradios.player').stop()` to stop.

- [ ] **Step 4: Verify pause and volume IPC**

While playing (from step 3):
```
:lua require('webradios.player').toggle_pause()
```
Expected: audio pauses. Run again to resume.

```
:lua require('webradios.player').volume_down()
:lua require('webradios.player').volume_down()
```
Expected: volume decreases.

- [ ] **Step 5: Commit**

```bash
git add lua/webradios/player.lua
git commit -m "feat: add player module with mpv IPC for pause and volume"
```

---

## Chunk 2: UI and Integration

### Task 4: UI module

**Files:**
- Create: `lua/webradios/ui.lua`

- [ ] **Step 1: Create the complete UI module file**

Write the complete `lua/webradios/ui.lua` file. The file assembles all functions defined in Steps 1-7 below in this exact order from top to bottom:

1. Module requires and state (this step)
2. `is_open()` and `get_dimensions()` helpers (this step)
3. Forward declarations for `render_status_bar` and `set_keybindings` (this step)
4. `render_status_bar` (Step 3)
5. `play_selected` (Step 6)
6. `new_search` (Step 5)
7. `trigger_search` (Step 4)
8. `render_results` (Step 2)
9. `set_keybindings` (Step 7)
10. `M.open()` and `M.close()` (this step)

Start the file with:

```lua
-- lua/webradios/ui.lua
local api = require("webradios.api")
local player = require("webradios.player")

local M = {}

local ui_state = {
  buf = nil,
  win = nil,
  stations = {},  -- current search results
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

-- Forward declarations
local render_status_bar
local set_keybindings

function M.open()
  if is_open() then
    -- Already open, just focus
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

  -- Initialize buffer content: search line + separator + empty + status
  vim.bo[ui_state.buf].modifiable = true
  local separator = string.rep("─", dim.width)
  vim.api.nvim_buf_set_lines(ui_state.buf, 0, -1, false, {
    "> ",
    separator,
    "",
    separator,
    "",
  })

  -- Set up highlight groups
  vim.api.nvim_set_hl(0, "WebradiosSearch", { bold = true })
  vim.api.nvim_set_hl(0, "WebradiosSeparator", { fg = "#555555" })
  vim.api.nvim_set_hl(0, "WebradiosStation", { bold = true })
  vim.api.nvim_set_hl(0, "WebradiosBitrate", { fg = "#888888" })
  vim.api.nvim_set_hl(0, "WebradiosStatus", { fg = "#aaaaaa", italic = true })

  set_keybindings()
  render_status_bar()

  -- Ensure buffer stays modifiable for insert mode on search line
  vim.bo[ui_state.buf].modifiable = true

  -- Register state change callback so status bar updates live
  player._on_state_change = function()
    if is_open() then
      render_status_bar()
    end
  end

  -- Clean up on buffer wipe
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = ui_state.buf,
    once = true,
    callback = function()
      ui_state.buf = nil
      ui_state.win = nil
      ui_state.stations = {}
      -- Keep the callback but make it a no-op check (is_open will be false)
    end,
  })

  -- Start in insert mode on search line
  vim.api.nvim_win_set_cursor(ui_state.win, { 1, 2 })
  vim.cmd("startinsert")
end

function M.close()
  if is_open() then
    vim.api.nvim_win_close(ui_state.win, true)
  end
end

return M
```

This is just the window shell. Next steps add rendering and keybindings.

- [ ] **Step 2: Add results rendering function**

Add this above the `M.open` function in `lua/webradios/ui.lua`:

```lua
local function render_results(stations, error_msg)
  if not is_open() then
    return
  end

  local dim = get_dimensions()
  ui_state.stations = stations or {}

  vim.bo[ui_state.buf].modifiable = true

  -- Keep search line (line 1) and separator (line 2)
  -- Replace everything from line 3 onward
  local lines = {}

  if error_msg then
    table.insert(lines, "  " .. error_msg)
  elseif #ui_state.stations == 0 then
    table.insert(lines, "  No stations found")
  else
    -- Column widths
    local name_w = math.max(20, math.floor(dim.width * 0.4))
    local country_w = 4
    local tags_w = math.max(10, math.floor(dim.width * 0.25))
    local bitrate_w = 8

    for _, s in ipairs(ui_state.stations) do
      local name = s.name
      if #name > name_w then
        name = name:sub(1, name_w - 1) .. "…"
      end

      local tags = s.tags
      if #tags > tags_w then
        tags = tags:sub(1, tags_w - 1) .. "…"
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

  -- Add separator and status bar placeholder
  local separator = string.rep("─", dim.width)
  table.insert(lines, separator)
  table.insert(lines, "")

  vim.api.nvim_buf_set_lines(ui_state.buf, 2, -1, false, lines)
  vim.bo[ui_state.buf].modifiable = false

  render_status_bar()

  -- Move cursor to first result if there are results
  if ui_state.stations and #ui_state.stations > 0 then
    vim.api.nvim_win_set_cursor(ui_state.win, { 3, 0 })
  end
end
```

- [ ] **Step 3: Add status bar rendering function**

Add this above `render_results` in `lua/webradios/ui.lua`:

```lua
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

  local line_count = vim.api.nvim_buf_line_count(ui_state.buf)
  -- Save and restore modifiable state to avoid locking the buffer
  -- when called while the user is typing on the search line
  local was_modifiable = vim.bo[ui_state.buf].modifiable
  vim.bo[ui_state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(ui_state.buf, line_count - 1, line_count, false, { " " .. status })
  vim.bo[ui_state.buf].modifiable = was_modifiable
end
```

- [ ] **Step 4: Add search trigger function**

Add above `render_results`:

```lua
local function trigger_search()
  if not is_open() then
    return
  end

  -- Get search term from line 1
  local search_line = vim.api.nvim_buf_get_lines(ui_state.buf, 0, 1, false)[1] or ""
  local keyword = search_line:gsub("^>%s*", ""):gsub("%s+$", "")

  if keyword == "" then
    return
  end

  -- Show searching indicator
  vim.bo[ui_state.buf].modifiable = true
  local dim = get_dimensions()
  local separator = string.rep("─", dim.width)
  vim.api.nvim_buf_set_lines(ui_state.buf, 2, -1, false, {
    "  searching...",
    separator,
    "",
  })
  vim.bo[ui_state.buf].modifiable = false

  -- Switch to normal mode
  vim.cmd("stopinsert")

  api.search(keyword, function(stations, err)
    render_results(stations, err)
  end)
end
```

- [ ] **Step 5: Add new search function (the `/` key handler)**

Add above `trigger_search`:

```lua
local function new_search()
  if not is_open() then
    return
  end

  ui_state.stations = {}

  vim.bo[ui_state.buf].modifiable = true

  local dim = get_dimensions()
  local separator = string.rep("─", dim.width)
  vim.api.nvim_buf_set_lines(ui_state.buf, 0, -1, false, {
    "> ",
    separator,
    "",
    separator,
    "",
  })

  render_status_bar()

  -- Ensure buffer stays modifiable for insert mode on search line
  vim.bo[ui_state.buf].modifiable = true
  vim.api.nvim_win_set_cursor(ui_state.win, { 1, 2 })
  vim.cmd("startinsert")
end
```

- [ ] **Step 6: Add play selected station function**

Add above `new_search`:

```lua
local function play_selected()
  if not is_open() then
    return
  end

  local cursor = vim.api.nvim_win_get_cursor(ui_state.win)
  local row = cursor[1]

  -- Results start at line 3 (index 1-based)
  local station_index = row - 2
  if station_index < 1 or station_index > #ui_state.stations then
    return
  end

  local station = ui_state.stations[station_index]
  player.play(station)
  api.register_click(station.stationuuid)
  render_status_bar()
end
```

- [ ] **Step 7: Add keybindings setup**

Implement the `set_keybindings` function:

```lua
set_keybindings = function()
  local buf = ui_state.buf
  local opts = { buffer = buf, noremap = true, silent = true, nowait = true }

  -- <CR> in normal mode: search if on line 1, play if on result line
  vim.keymap.set("n", "<CR>", function()
    local row = vim.api.nvim_win_get_cursor(ui_state.win)[1]
    if row == 1 then
      trigger_search()
    else
      play_selected()
    end
  end, opts)

  -- <CR> in insert mode (only fires on line 1): trigger search
  vim.keymap.set("i", "<CR>", function()
    trigger_search()
  end, opts)

  -- / — new search
  vim.keymap.set("n", "/", function()
    new_search()
  end, opts)

  -- p — toggle pause
  vim.keymap.set("n", "p", function()
    player.toggle_pause()
  end, opts)

  -- s — stop
  vim.keymap.set("n", "s", function()
    player.stop()
  end, opts)

  -- + — volume up
  vim.keymap.set("n", "+", function()
    player.volume_up()
  end, opts)

  -- - — volume down
  vim.keymap.set("n", "-", function()
    player.volume_down()
  end, opts)

  -- q / <Esc> — close overlay
  vim.keymap.set("n", "q", function()
    M.close()
  end, opts)
  vim.keymap.set("n", "<Esc>", function()
    M.close()
  end, opts)
end
```

- [ ] **Step 8: Verify UI opens with empty state**

```
nvim --cmd "set rtp+=." -c "lua require('webradios.ui').open()"
```
Expected: a centered floating window appears with `> ` search line, separator, and status bar showing `⏹ Stopped`. Cursor is in insert mode on line 1.

- [ ] **Step 9: Verify search and results**

With the overlay open, type `jazz` and press `<CR>`.
Expected: "searching..." appears briefly, then a list of stations fills the window with aligned columns. Cursor moves to the first result.

- [ ] **Step 10: Verify playback from results**

Press `<CR>` on a station.
Expected: audio starts playing. Status bar updates to show `▶ StationName — bitrate | Vol: 80%`.

- [ ] **Step 11: Verify controls**

- Press `p` → audio pauses, status shows `⏸`
- Press `p` → audio resumes, status shows `▶`
- Press `+` → volume increases (status updates)
- Press `-` → volume decreases (status updates)
- Press `s` → audio stops, status shows `⏹ Stopped`
- Press `/` → search line clears, ready for new search in insert mode
- Press `q` → overlay closes

- [ ] **Step 12: Commit**

```bash
git add lua/webradios/ui.lua
git commit -m "feat: add UI module with floating window, search, and playback controls"
```

---

### Task 5: Init module (public API)

**Files:**
- Create: `lua/webradios/init.lua`

- [ ] **Step 1: Create init module**

```lua
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
```

- [ ] **Step 2: Verify public API**

```
nvim --cmd "set rtp+=." -c "lua print(require('webradios').status())"
```
Expected: prints empty string (nothing playing).

```
nvim --cmd "set rtp+=." -c "lua require('webradios').open()"
```
Expected: floating window opens.

- [ ] **Step 3: Commit**

```bash
git add lua/webradios/init.lua
git commit -m "feat: add init module with setup, open, and status API"
```

---

### Task 6: Plugin entry point

**Files:**
- Create: `plugin/webradios.lua`

- [ ] **Step 1: Create plugin entry point**

```lua
-- plugin/webradios.lua
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
```

- [ ] **Step 2: Verify command and plug mapping**

```
nvim --cmd "set rtp+=." -c "Webradios"
```
Expected: floating window opens.

```
nvim --cmd "set rtp+=." -c "nmap <leader>wr <Plug>(webradios-open)" -c "normal <leader>wr"
```
Expected: floating window opens via plug mapping.

- [ ] **Step 3: Commit**

```bash
git add plugin/webradios.lua
git commit -m "feat: add plugin entry point with :Webradios command and Plug mapping"
```

---

### Task 7: End-to-end verification

- [ ] **Step 1: Full flow test**

```
nvim --cmd "set rtp+=."
```

1. Run `:Webradios` — overlay opens
2. Type `rock` and press `<CR>` — stations appear
3. Press `<CR>` on a station — music plays, status bar updates
4. Press `p` — pauses
5. Press `p` — resumes
6. Press `+` twice — volume up
7. Press `-` — volume down
8. Press `/` — new search, type `jazz`, press `<CR>` — new results
9. Press `<CR>` on a station — old stream stops, new one plays
10. Press `q` — overlay closes, music continues
11. Run `:Webradios` again — overlay opens, shows status of playing station
12. Press `s` — music stops
13. Press `<Esc>` — overlay closes

All 13 steps must pass.

- [ ] **Step 2: Verify statusline API**

While a station is playing:
```
:lua print(require('webradios').status())
```
Expected: prints `▶ StationName — bitrate`.

After stopping:
```
:lua print(require('webradios').status())
```
Expected: prints empty string.

- [ ] **Step 3: Final commit if any fixes were needed**

```bash
git add -A
git commit -m "fix: address issues found during end-to-end testing"
```

Only run this if changes were made during testing.
