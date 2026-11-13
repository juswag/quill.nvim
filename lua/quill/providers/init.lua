local http = require("quill.providers.http")
local cli = require("quill.providers.cli")

return {
  mock = require("quill.providers.mock"),
  openai = http.new("openai"),
  anthropic = http.new("anthropic"),
  codex = cli.new("codex"),
  claude_code = cli.new("claude_code"),
  copilot = require("quill.providers.copilot"),
}
