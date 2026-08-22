-- Highlight, edit, and navigate code
--
-- NOTE: This uses the `main` branch of nvim-treesitter, which is a full,
-- incompatible rewrite of the old `master` branch. `master` is frozen and
-- receives no further parser updates. See `:help nvim-treesitter`.
--
-- What changed from `master`:
--   * No `require('nvim-treesitter.configs').setup()` and no `opts` modules.
--     Highlighting, indentation and folding are Neovim features now; this
--     plugin only ships parsers + queries and the install/update commands.
--   * Highlighting is turned on per-buffer with `vim.treesitter.start()`.
--   * Indentation is opt-in via `indentexpr`.
--   * `auto_install` no longer exists; the FileType autocmd below reimplements
--     it so behaviour matches the previous config.
--   * The plugin does not support lazy-loading, hence `lazy = false`.
return {
  {
    'nvim-treesitter/nvim-treesitter',
    branch = 'main',
    lazy = false,
    build = ':TSUpdate',
    config = function()
      local ts = require 'nvim-treesitter'

      ts.setup {
        -- Parsers and queries are installed here and prepended to runtimepath.
        install_dir = vim.fn.stdpath 'data' .. '/site',
      }

      -- Parsers to always keep installed. The first group is the kickstart
      -- default; the rest were picked up by the old `auto_install = true` and
      -- are listed explicitly so they survive the move to `main`.
      local ensure_installed = {
        'bash',
        'c',
        'diff',
        'html',
        'lua',
        'luadoc',
        'markdown',
        'markdown_inline',
        'query',
        'vim',
        'vimdoc',
        'astro',
        'gitignore',
        'javascript',
        'json',
        'make',
        'python',
        'requirements',
        'ssh_config',
        'toml',
        'typescript',
        -- NOTE: `tmux` was installed under the old `master` branch but is not
        -- among the parsers supported on `main`, so it is intentionally absent.
      }

      -- Languages that depend on vim's regex highlighting for correct indent
      -- rules. Treesitter indent is disabled and `:syntax` is left on for these.
      local regex_highlight = { ruby = true }

      -- `install()` is async and a no-op for parsers already present.
      ts.install(ensure_installed)

      -- Cache of installed parsers so the FileType autocmd below stays cheap.
      local installed
      local function is_installed(lang)
        if not installed then
          installed = {}
          for _, l in ipairs(ts.get_installed 'parsers') do
            installed[l] = true
          end
        end
        return installed[lang] == true
      end

      local available
      local function is_available(lang)
        if not available then
          available = {}
          -- `get_available()` takes an optional tier, not a type; no args = all.
          for _, l in ipairs(ts.get_available()) do
            available[l] = true
          end
        end
        return available[lang] == true
      end

      local function start(buf, lang)
        if not vim.api.nvim_buf_is_valid(buf) then
          return
        end
        pcall(vim.treesitter.start, buf, lang)
        if regex_highlight[lang] then
          -- Equivalent of the old `additional_vim_regex_highlighting`:
          -- `vim.treesitter.start()` clears 'syntax', so restore it to run regex
          -- highlighting alongside treesitter. The value must be the syntax
          -- script name (the filetype), not 'on'. Indent is left to vim's own
          -- ftplugin (the old `indent.disable`).
          vim.bo[buf].syntax = vim.bo[buf].filetype
        else
          vim.bo[buf].indentexpr = "v:lua.require'nvim-treesitter'.indentexpr()"
        end
      end

      -- Enable treesitter highlighting/indent per filetype, installing the
      -- parser on demand. This replaces the old `auto_install = true`.
      vim.api.nvim_create_autocmd('FileType', {
        group = vim.api.nvim_create_augroup('kickstart-treesitter', { clear = true }),
        callback = function(args)
          local buf = args.buf
          local lang = vim.treesitter.language.get_lang(args.match)
          if not lang then
            return
          end

          if is_installed(lang) then
            start(buf, lang)
          elseif is_available(lang) then
            ts.install({ lang }):await(function()
              installed = nil -- refresh cache on next lookup
              vim.schedule(function()
                start(buf, lang)
              end)
            end)
          end
        end,
      })
    end,
  },
}
