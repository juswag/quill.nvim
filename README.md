<p align="center"><img src="assets/banner.png" alt="quill.nvim" width="100%"></p>

Select code, describe the change, and watch the rewrite stream in as a preview drawn over
your code. Accept or reject each hunk. The buffer is not touched until you finish
reviewing, and everything you accepted lands as one undo step.

![quill.nvim demo](assets/demo.gif)

Requires Neovim 0.10 or newer and `curl`.

## Install

[lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{ "juswag/quill.nvim", opts = {} }
```

`opts` is passed to `require("quill").setup()`, which also creates the `<leader>k` visual-mode
mapping. With another plugin manager, call `require("quill").setup({})` yourself.

## Configuration

Defaults:

```lua
require("quill").setup({
  provider = "openai",        -- a key of `providers`
  providers = {
    openai = { base_url = "https://api.openai.com/v1", model = "gpt-4o-mini", api_key_env = "OPENAI_API_KEY" },
    anthropic = { base_url = "https://api.anthropic.com/v1", model = "claude-sonnet-4-5", api_key_env = "ANTHROPIC_API_KEY" },
    mock = {},                -- offline provider used by the tests and the demo
  },
  context_lines = 20,         -- lines above and below the selection sent as context
  mapping = "<leader>k",      -- visual-mode mapping, false to disable
  keys = {
    accept = "a", reject = "r", accept_all = "A", reject_all = "R",
    next = "]h", prev = "[h", followup = "f", cancel = { "q", "<Esc>" },
  },
})
```

Examples:

```lua
-- Anthropic
opts = { provider = "anthropic" }

-- A different OpenAI model
opts = { providers = { openai = { model = "gpt-4.1" } } }

-- Ollama, or any OpenAI-compatible server (LM Studio, vLLM, OpenRouter)
opts = {
  provider = "ollama",
  providers = {
    ollama = { format = "openai", base_url = "http://localhost:11434/v1", model = "qwen2.5-coder", api_key = "ollama" },
  },
}
```

API keys are read from the environment variable named by `api_key_env`. A provider entry
with `format = "openai"` or `format = "anthropic"` reuses that wire format under its own name.

## Usage

1. Select lines in visual mode and press `<leader>k`, or run `:'<,'>Quill`.
   `:'<,'>Quill make this async` skips the prompt.
2. Type the instruction and press `<CR>`. `<Esc>` closes the prompt.
3. The proposal streams in. Removed lines get a soft red background, added lines appear as
   green virtual lines, and the changed words are marked in a stronger shade. The buffer
   text does not change.
4. Review with these keys, active in the buffer while the session is open:

| Key | Action |
| --- | --- |
| `a` / `r` | Accept or reject the current hunk, then move to the next pending one |
| `A` / `R` | Accept or reject every remaining hunk |
| `]h` / `[h` | Next or previous pending hunk |
| `f` | Follow-up prompt that refines the current proposal |
| `q` / `<Esc>` | Cancel. Stops the request and clears the preview |

When no pending hunks remain, the accepted hunks are written in one change, so a single `u`
restores the original. Rejecting everything writes nothing. `:QuillCancel` ends a session
from anywhere in the buffer.

## How it works

![Architecture](docs/arch.png)

| Module | Role |
| --- | --- |
| `quill/init.lua` | Session controller. A transition table (`prompting → streaming → reviewing → closed`, with follow-up looping back to `prompting`) owns every state change. An extmark tracks the edited range, so follow-ups stay anchored. |
| `quill/context.lua` | Builds the request: filetype, surrounding lines, diagnostics in the range, the enclosing Treesitter node, the selection, and the instruction. Follow-ups add the previous proposal as an assistant turn. |
| `quill/providers/` | `stream(request, opts, callbacks) -> { cancel }`. `http.lua` runs curl through `vim.system` and decodes server-sent events; each wire format is one table entry. `mock.lua` streams a canned reply on a timer. |
| `quill/hunks.lua` | Pure diff model. `compute` turns `vim.diff` output into hunks, `merge` builds the final text from the accepted ones, `inline` finds the changed words in a line pair. |
| `quill/render.lua` | Draws the preview with extmarks only: line and word highlights, virtual lines, signs, key chips, and the status float. |
| `quill/prompt.lua` | The floating instruction input. |

Highlights are mixed from your colorscheme's `DiagnosticError` and `DiagnosticOk` colors over
its `Normal` background and recomputed on `ColorScheme`. Every group is named `Quill*` and
defined with `default = true`, so you can override it. See `:help quill-highlights`.

## Development

```sh
./test.sh                 # headless suites in tests/test_*.lua
NVIM=/path/to/nvim ./test.sh
```

The suites drive the plugin through real keystrokes with the mock provider, and run curl
against a local server (`tests/sse_server.py`) for both wire formats. They need `nvim`,
`curl`, and `python3`. `demo/record.sh` re-records the demo (tmux, asciinema 3, agg, ffmpeg).

## Limitations

- Hunks are line diffs, and selections are widened to whole lines.
- A follow-up re-diffs against the original selection and resets hunk decisions.
- Editing text inside the range during a session is not handled.
- Session keys shadow normal-mode keys while a session is open.

## Roadmap

- Generate at the cursor without a selection
- Next-edit suggestions
- Saved prompts
- A documented Lua API

## License

[MIT](LICENSE)
