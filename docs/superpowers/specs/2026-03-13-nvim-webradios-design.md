# nvim-webradios Design Spec

## Overview

A Neovim plugin that lets users search and listen to internet radio stations from within the editor. Uses the radio-browser.info API for station discovery and mpv for audio playback.

## Plugin Structure

```
nvim-webradios/
  lua/webradios/
    init.lua       -- M.setup(), M.open(), M.status(), public API
    config.lua     -- defaults merged with user opts
    api.lua        -- curl-based async HTTP to radio-browser.info
    player.lua     -- mpv process lifecycle (play, pause, stop, volume)
    ui.lua         -- floating window, rendering, keybindings
  plugin/
    webradios.lua  -- :Webradios command + <Plug>(webradios-open)
```

## Configuration

Via `setup()` with sensible defaults. Plugin works without calling `setup()`.

```lua
require("webradios").setup({
  api_url = "https://all.api.radio-browser.info",
  limit = 30,
  player = "mpv",
  volume = 80,
  volume_step = 5,
})
```

## Entry Points

- `:Webradios` user command
- `<Plug>(webradios-open)` mapping
- `require("webradios").status()` for statusline integration

## API Layer (`api.lua`)

Communicates with radio-browser.info using async curl via `vim.fn.jobstart`.

**Endpoint:**
```
GET /json/stations/search?name={keyword}&limit={limit}&hidebroken=true&order=votes&reverse=true
```

Orders by votes descending to surface popular/reliable stations first.

**Flow:**
1. User hits `<CR>` on search line -> `api.search(keyword, callback)`
2. Spawns `curl -s -H "User-Agent: nvim-webradios" <url>` via `jobstart`
3. On completion, parses JSON with `vim.json.decode`
4. Calls `callback(stations)` with tables containing: `stationuuid`, `name`, `url_resolved`, `country`, `tags`, `bitrate`, `codec`
5. On error, calls `callback(nil, error_message)`

Non-blocking callback pattern keeps the UI responsive.

**Search cancellation:** A new search cancels any in-flight curl job via `vim.fn.jobstop()` before starting the new one. The module tracks the current `search_job_id`.

**Station click tracking:** When a station is played, the API module fires a background request to `/json/url/{stationuuid}` to register a "click". This is good API citizenship and helps community rankings.

## Player Module (`player.lua`)

Manages a single mpv process for playback.

### State

Module-level table tracking:
- `job_id` — Neovim job handle (nil when stopped)
- `ipc_socket` — path to the mpv IPC UNIX socket
- `station` — currently playing station table
- `paused` — boolean
- `volume` — current volume level

### mpv Invocation

```
mpv --no-video --terminal=no --volume={vol} --input-ipc-server=/tmp/nvim-webradios-{pid}.sock {url_resolved}
```

Uses `--input-ipc-server` to create a UNIX socket for runtime control (pause, volume) without restarting mpv. The `{pid}` is `vim.fn.getpid()` to avoid socket collisions across multiple Neovim instances.

### IPC Communication

Commands are sent to mpv via the UNIX socket using `vim.uv.new_pipe()`. Each JSON command must be terminated with `\n`:
- Pause toggle: `{"command": ["cycle", "pause"]}`
- Set volume: `{"command": ["set", "volume", <value>]}`

This avoids SIGSTOP/SIGCONT (which can cause audio glitches) and mpv restarts (which cause multi-second gaps while reconnecting to the stream).

The socket file is cleaned up on `player.stop()` and on Neovim exit (via `VimLeavePre` autocmd registered in `player.lua` at module load time).

### Public Functions

- `player.play(station)` — stops current playback, starts mpv with `url_resolved` and IPC socket
- `player.stop()` — calls `vim.fn.jobstop(job_id)`, removes socket file, clears state
- `player.toggle_pause()` — sends `cycle pause` via IPC socket
- `player.volume_up()` / `player.volume_down()` — sends `set volume` via IPC socket
- `player.get_state()` — returns state table for UI/statusline

On process exit (`on_exit` callback): clears state and removes socket file. If the overlay is closed when mpv exits, only state is cleared silently; the UI is updated on next open.

## UI Module (`ui.lua`)

Single floating window, mode-based interaction.

### Window Layout

```
┌──────────── Web Radios ─────────────┐
│ > jazz                              │  <- line 1: search input
│─────────────────────────────────────│  <- line 2: separator
│   Jazz FM          UK    jazz  128  │  <- results start at line 3
│   Jazz Radio       FR    jazz  320  │
│   Smooth Jazz      US    smooth 256 │
│   ...                               │
│─────────────────────────────────────│
│ ▶ Jazz FM — 128 kbps | Vol: 80%    │  <- last line: status bar
└─────────────────────────────────────┘
```

- Centered, ~70% width, ~60% height of editor
- `border = "rounded"`, title `" Web Radios "`
- Buffer: `nofile`, `bufhidden = wipe`

### Search Line (Line 1)

- On open, cursor on line 1 in insert mode, buffer is modifiable
- `<CR>` is mapped in both insert and normal mode on line 1 to trigger search
- On search trigger: switch to normal mode, set buffer non-modifiable, show `> searching...`
- After results arrive, cursor moves to first result (line 3)
- Pressing `/` sets buffer modifiable, clears results, moves cursor to line 1 in insert mode
- Result lines are overwritten on each search — no need to prevent editing since modifiable is off

### Results Rendering

- One line per station with aligned columns: name, country code, tags (truncated), bitrate
- Buffer set non-modifiable after rendering (toggle `vim.bo.modifiable`)
- Highlight groups for visual distinction (station name bold, bitrate dimmed)

### Status Bar (Last Line)

- Shows playback state: `▶ Station Name — 128 kbps | Vol: 80%`, `⏸ ...`, or `⏹ Stopped`
- Updated on player state changes

### Keybindings (buffer-local)

| Key       | Action                                          |
|-----------|-------------------------------------------------|
| `<CR>`    | Line 1: search. On result line: play station    |
| `/`       | Clear results, go to line 1 in insert mode      |
| `p`       | Toggle pause/resume                             |
| `s`       | Stop playback                                   |
| `+`       | Volume up                                       |
| `-`       | Volume down                                     |
| `q`/`<Esc>` | Close overlay (playback continues)           |

### Statusline API

`require("webradios").status()` returns a string like `▶ Jazz FM — 128 kbps` or `""` when idle. Users integrate in lualine or any statusline.

## Playback Persistence

Closing the overlay does not stop playback. Music continues in the background. Reopening the overlay shows current playback state.

## Error Handling

- **Network/curl failure:** Show `"Error: could not reach radio-browser API"` on line 3
- **No results:** Show `"No stations found for '{keyword}'"` on line 3
- **mpv not found:** `vim.notify("mpv not found. Install it to play stations.", ERROR)` on first play attempt
- **mpv crash / stream dies:** `on_exit` clears state, status bar shows `⏹ Stopped`
- **JSON parse error:** Treated as "no results" with generic error message

No retries or complex recovery. User can always try again with `/`.

## Dependencies

- **mpv** — external, must be installed by user
- **curl** — external, typically available on all systems
- **Neovim >= 0.9** — for floating window title support
