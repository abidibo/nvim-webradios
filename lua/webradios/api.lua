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
