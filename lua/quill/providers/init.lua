local http = require("quill.providers.http")

return {
  mock = require("quill.providers.mock"),
  openai = http.new("openai"),
  anthropic = http.new("anthropic"),
}
