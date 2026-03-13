# nvim-webradios

Search and listen to internet radio stations from within Neovim.

![Neovim](https://img.shields.io/badge/Neovim-%3E%3D0.9-green?logo=neovim)

```
┌──────────────────────── Web Radios ─────────────────────────┐
│ > jazz                                                      │
│─────────────────────────────────────────────────────────────│
│  Jazz FM                    UK   jazz, smooth jazz  128 kbps│
│  Jazz Radio                 FR   jazz               320 kbps│
│  Smooth Jazz CD101.9        US   smooth jazz        256 kbps│
│  ...                                                        │
│─────────────────────────────────────────────────────────────│
│ ▶ Jazz FM — 128 kbps | Vol: 80%                             │
└─────────────────────────────────────────────────────────────┘
```

## Features

- Search 30,000+ radio stations via [radio-browser.info](https://www.radio-browser.info/)
- Play, pause, stop with a single keypress
- Volume control inside the overlay
- Playback continues when the overlay is closed
- Statusline integration (lualine, etc.)
- Async everywhere — never blocks your editor

## Requirements

- **Neovim >= 0.9**
- **[mpv](https://mpv.io/)** — audio player
- **curl** — for API requests (usually pre-installed)

### Install mpv

```bash
# Ubuntu/Debian
sudo apt install mpv

# Arch
sudo pacman -S mpv

# macOS
brew install mpv

# Fedora
sudo dnf install mpv
```

## Installation

### [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  "abidibo/nvim-webradios",
  cmd = "Webradios",
  keys = {
    { "<leader>wr", "<Plug>(webradios-open)", desc = "Web Radios" },
  },
  opts = {},
}
```

### [packer.nvim](https://github.com/wbthomason/packer.nvim)

```lua
use {
  "abidibo/nvim-webradios",
  config = function()
    require("webradios").setup()
  end,
}
```

### Manual

Clone the repo and add it to your runtimepath:

```lua
vim.opt.rtp:prepend("~/path/to/nvim-webradios")
```

## Configuration

The plugin works out of the box with no configuration. Call `setup()` only if you want to override defaults:

```lua
require("webradios").setup({
  -- Radio Browser API URL (uses DNS round-robin by default)
  api_url = "https://all.api.radio-browser.info",

  -- Max number of search results
  limit = 30,

  -- Audio player binary
  player = "mpv",

  -- Initial volume (0-100)
  volume = 80,

  -- Volume increment for +/- keys
  volume_step = 5,
})
```

## Usage

### Opening the overlay

Use the `:Webradios` command or map the provided `<Plug>` mapping:

```lua
vim.keymap.set("n", "<leader>wr", "<Plug>(webradios-open)")
```

### Keybindings (inside the overlay)

| Key | Mode | Action |
|-----|------|--------|
| `<CR>` | Insert (line 1) | Search stations |
| `<CR>` | Normal (line 1) | Search stations |
| `<CR>` | Normal (result) | Play selected station |
| `/` | Normal | Start a new search |
| `p` | Normal | Toggle pause/resume |
| `s` | Normal | Stop playback |
| `+` | Normal | Volume up |
| `-` | Normal | Volume down |
| `q` | Normal | Close overlay |
| `<Esc>` | Normal | Close overlay |

### Workflow

1. Open the overlay (`:Webradios` or your keybinding)
2. Type a search term (e.g. `jazz`, `rock`, `classical`) and press `<CR>`
3. Browse results — stations are sorted by popularity
4. Press `<CR>` on a station to start playing
5. Use `p` to pause, `+`/`-` for volume, `s` to stop
6. Press `/` to search for something else
7. Press `q` to close — **music keeps playing**
8. Reopen anytime to see what's playing and access controls

## Statusline Integration

The plugin exposes `require("webradios").status()` which returns a string like `▶ Jazz FM — 128 kbps` when playing, or an empty string when idle.

### [lualine.nvim](https://github.com/nvim-lualine/lualine.nvim)

```lua
require("lualine").setup({
  sections = {
    lualine_x = {
      {
        function()
          return require("webradios").status()
        end,
        cond = function()
          return require("webradios").status() ~= ""
        end,
      },
      "encoding",
      "fileformat",
      "filetype",
    },
  },
})
```

This adds the currently playing station to the `lualine_x` section, and only shows it when something is actually playing.

If you want it in a different section, just move the block. For example, to show it on the right side of the statusline:

```lua
lualine_z = {
  {
    function()
      return require("webradios").status()
    end,
    cond = function()
      return require("webradios").status() ~= ""
    end,
    color = { fg = "#a6e3a1" }, -- optional: custom color
  },
  "location",
},
```

### Other statusline plugins

For any statusline plugin that accepts a function, use:

```lua
require("webradios").status()
```

It returns:
- `"▶ Station Name — 128 kbps"` when playing
- `"⏸ Station Name — 128 kbps"` when paused
- `""` (empty string) when stopped/idle

## API

| Function | Description |
|----------|-------------|
| `require("webradios").setup(opts)` | Configure the plugin (optional) |
| `require("webradios").open()` | Open the radio browser overlay |
| `require("webradios").status()` | Get current playback status string |

## How it works

- Stations are fetched from the [Radio Browser API](https://api.radio-browser.info/), a free and open community database
- Audio playback is handled by [mpv](https://mpv.io/) running in the background
- Pause and volume are controlled via mpv's IPC socket — no audio interruption
- Each Neovim instance gets its own socket (`/tmp/nvim-webradios-{pid}.sock`), so multiple instances don't conflict
- The socket is cleaned up automatically when Neovim exits

## License

MIT
