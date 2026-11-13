-- GitHub Copilot chat through an existing copilot.vim / copilot.lua sign-in.
-- The token exchange is Copilot's internal, undocumented API, so GitHub can change it.
local http = require("quill.providers.http")
local openai = http.formats.openai

local defaults = {
  model = "gpt-5-mini",
  token_url = "https://api.github.com/copilot_internal/v2/token",
  base_url = "https://api.githubcopilot.com",
}

-- Short-lived API token, reused until a minute before it expires.
local cache

local function config_dir()
  local xdg = vim.env.XDG_CONFIG_HOME
  return ((xdg and xdg ~= "") and xdg or vim.fs.normalize("~/.config")) .. "/github-copilot"
end

local function read_oauth_token(dir)
  for _, file in ipairs({ "apps.json", "hosts.json" }) do
    local path = dir .. "/" .. file
    if vim.fn.filereadable(path) == 1 then
      local ok, data = pcall(vim.json.decode, table.concat(vim.fn.readfile(path), "\n"))
      if ok and type(data) == "table" then
        for host, entry in pairs(data) do
          if host:find("github.com", 1, true) and type(entry) == "table" and entry.oauth_token then
            return entry.oauth_token
          end
        end
      end
    end
  end
end

local function editor_headers()
  local v = vim.version()
  return {
    ("Editor-Version: Neovim/%d.%d.%d"):format(v.major, v.minor, v.patch),
    "Editor-Plugin-Version: quill.nvim/0.1.0",
    "Copilot-Integration-Id: vscode-chat",
    "User-Agent: quill.nvim/0.1.0",
  }
end

--- Calls back with (err, cache_entry). Returns the curl job so it can be killed.
local function exchange(oauth, opts, done)
  if cache and cache.oauth == oauth and cache.expires_at - 60 > os.time() then
    done(nil, cache)
    return nil
  end
  local cmd = { "curl", "-sS", "--fail-with-body", opts.token_url, "-H", "Authorization: token " .. oauth, "-H", "Accept: application/json" }
  for _, h in ipairs(editor_headers()) do
    vim.list_extend(cmd, { "-H", h })
  end
  return vim.system(cmd, { text = true }, function(res)
    vim.schedule(function()
      local ok, body = pcall(vim.json.decode, res.stdout or "")
      if res.code ~= 0 or not ok or type(body) ~= "table" or not body.token then
        local detail = vim.trim((res.stdout or "") .. (res.stderr or "")):sub(1, 300)
        return done(("Copilot token exchange failed (%s). Is your Copilot subscription active?"):format(detail))
      end
      cache = {
        oauth = oauth,
        token = body.token,
        expires_at = tonumber(body.expires_at) or (os.time() + 600),
        api = type(body.endpoints) == "table" and body.endpoints.api or nil,
      }
      done(nil, cache)
    end)
  end)
end

return function(req, opts, cb)
  opts = vim.tbl_extend("force", defaults, opts or {})
  local dir = opts.config_dir or config_dir()
  local oauth = read_oauth_token(dir)
  if not oauth then
    cb.on_error(("no Copilot sign-in found in %s/{apps,hosts}.json. Sign in once with copilot.vim (:Copilot setup) or copilot.lua (:Copilot auth)."):format(dir))
    return { cancel = function() end }
  end

  local cancelled, job, stream = false, nil, nil
  job = exchange(oauth, opts, function(err, entry)
    if cancelled then
      return
    end
    if err then
      return cb.on_error(err)
    end
    local base = entry.api or opts.base_url
    local url, headers, body = openai.request(req, { base_url = base, model = opts.model, temperature = opts.temperature }, entry.token)
    vim.list_extend(headers, editor_headers())
    stream = http.stream(url, headers, body, openai.extract, {
      on_chunk = cb.on_chunk,
      on_done = cb.on_done,
      on_error = function(e)
        if e:find("401", 1, true) then
          cache = nil
        end
        cb.on_error(e)
      end,
    })
  end)

  return {
    cancel = function()
      cancelled = true
      if stream then
        stream.cancel()
      elseif job then
        pcall(function()
          job:kill("sigterm")
        end)
      end
    end,
  }
end
