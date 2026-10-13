-- AI and code assistance tools

-- Local Ollama (Ollama.app on the Studio) shared by avante and ollama.nvim.
-- Must be a model listed by `ollama list`.
local ollama_url = 'http://127.0.0.1:11434'
local ollama_model = 'qwen3-coder-next:q4_K_M'

return {
  -- GitHub Copilot
  {
    'zbirenbaum/copilot.lua',
    cmd = 'Copilot',
    event = 'InsertEnter',
    config = function()
      require('copilot').setup({
        panel = {
          enabled = true,
          auto_refresh = false,
          keymap = {
            jump_prev = "[[",
            jump_next = "]]",
            accept = "<CR>",
            refresh = "gr",
            open = "<M-CR>"
          },
          layout = {
            position = "bottom", -- | top | left | right
            ratio = 0.4
          },
        },
        suggestion = {
          enabled = false, -- Disable autosuggestions by default
          auto_trigger = false,
          debounce = 75,
          keymap = {
            accept = "<S-Tab>", -- Use Shift+Tab to accept suggestions
            accept_word = false,
            accept_line = false,
            next = "<M-]>",
            prev = "<M-[>",
            dismiss = "<C-]>",
          },
        },
        filetypes = {
          yaml = false,
          markdown = false,
          help = false,
          gitcommit = false,
          gitrebase = false,
          hgcommit = false,
          svn = false,
          cvs = false,
          ["."] = false,
        },
        copilot_node_command = 'node', -- Node.js version must be > 18.x
        server_opts_overrides = {},
      })
    end,
  },
  -- Avante.nvim - AI pair programming
  {
    'yetone/avante.nvim',
    -- if you want to build from source then do `make BUILD_FROM_SOURCE=true`
    -- ⚠️ must add this setting! ! !
    build = vim.fn.has 'win32' ~= 0 and 'powershell -ExecutionPolicy Bypass -File Build.ps1 -BuildFromSource false' or 'make',
    event = 'VeryLazy',
    version = false, -- Never set this value to "*"! Never!
    keys = {
      -- Explain the current line (normal) or selection (visual) in the avante sidebar.
      -- avante reads the selection from the live visual mode, so this must stay a function.
      {
        '<leader>ae',
        function()
          if vim.fn.mode() == 'n' then
            vim.cmd 'normal! V'
          end
          require('avante.api').ask { question = 'Explain what this code does, line by line.', new_chat = true }
        end,
        desc = 'avante: explain code',
        mode = { 'n', 'v' },
      },
    },
    ---@module 'avante'
    ---@type avante.Config
    opts = {
      -- add any opts here
      -- this file can contain specific instructions for your project
      instructions_file = 'avante.md',
      -- <leader>ae is the explain keymap above; move avante's edit off it
      mappings = {
        edit = '<leader>aE',
      },
      -- for example
      -- Local Ollama through its OpenAI-compatible /v1 API. avante's native
      -- 'ollama' provider parses tool calls out of text (ReAct) and then never
      -- runs them, so file edits hang on "Tool calling". The openai provider
      -- uses real tool calls instead.
      provider = 'ollama_openai',

      providers = {
        ollama_openai = {
          __inherited_from = 'openai',
          endpoint = ollama_url .. '/v1',
          model = ollama_model,
          api_key_name = '', -- local Ollama needs no key
          timeout = 120000, -- large local models can take a while to load
          use_ReAct_prompt = false,
        },
        -- Native provider, kept for :AvanteSwitchProvider ollama (chat only)
        ollama = {
          endpoint = ollama_url,
          model = ollama_model,
          timeout = 120000, -- large local models can take a while to load
          -- avante treats ollama as disabled unless this is overridden
          is_env_set = function() return require('avante.providers.ollama').check_endpoint_alive() end,
        },
      },
      -- provider = 'claude',
      -- providers = {
      --   claude = {
      --     endpoint = 'https://api.anthropic.com',
      --     model = 'claude-sonnet-4-20250514',
      --     timeout = 30000, -- Timeout in milliseconds
      --     extra_request_body = {
      --       temperature = 0.75,
      --       max_tokens = 20480,
      --     },
      --   },
      --   moonshot = {
      --     endpoint = 'https://api.moonshot.ai/v1',
      --     model = 'kimi-k2-0711-preview',
      --     timeout = 30000, -- Timeout in milliseconds
      --     extra_request_body = {
      --       temperature = 0.75,
      --       max_tokens = 32768,
      --     },
      --   },
      -- },
    },
    dependencies = {
      'nvim-lua/plenary.nvim',
      'MunifTanjim/nui.nvim',
      --- The below dependencies are optional,
      'nvim-telescope/telescope.nvim', -- for file_selector provider telescope
      'folke/snacks.nvim', -- for input provider snacks
      'nvim-tree/nvim-web-devicons', -- or echasnovski/mini.icons
      {
        -- support for image pasting
        'HakonHarnes/img-clip.nvim',
        event = 'VeryLazy',
        opts = {
          -- recommended settings
          default = {
            embed_image_as_base64 = false,
            prompt_for_file_name = false,
            drag_and_drop = {
              insert_mode = true,
            },
            -- required for Windows users
            use_absolute_path = true,
          },
        },
      },
      {
        -- Make sure to set this up properly if you have lazy=true
        'MeanderingProgrammer/render-markdown.nvim',
        opts = {
          file_types = { 'markdown', 'Avante' },
        },
        ft = { 'markdown', 'Avante' },
      },
    },
  },

  -- Ollama integration
  {
    'nomnivore/ollama.nvim',
    dependencies = {
      'nvim-lua/plenary.nvim',
    },

    -- All the user commands added by the plugin
    cmd = { 'Ollama', 'OllamaModel', 'OllamaServe', 'OllamaServeStop' },

    keys = {
      -- Sample keybind for prompt menu. Note that the <c-u> is important for selections to work properly.
      {
        '<leader>oo',
        ":<c-u>lua require('ollama').prompt()<cr>",
        desc = 'ollama prompt',
        mode = { 'n', 'v' },
      },

      -- Explain the visual selection
      {
        '<leader>oe',
        ":<c-u>lua require('ollama').prompt('Explain_Code')<cr>",
        desc = 'ollama Explain Code',
        mode = 'v',
      },

      -- Sample keybind for direct prompting. Note that the <c-u> is important for selections to work properly.
      {
        '<leader>oG',
        ":<c-u>lua require('ollama').prompt('Generate_Code')<cr>",
        desc = 'ollama Generate Code',
        mode = { 'n', 'v' },
      },

      -- AI-written reST docstring for the Python function/class under the cursor.
      -- The model only returns text; custom.docstring inserts it, so code is never edited.
      -- <leader>cd (plugins/editor.lua) is the neogen skeleton.
      {
        '<leader>cD',
        function()
          require('custom.docstring').generate { url = ollama_url, model = ollama_model }
        end,
        desc = '[C]ode [D]ocstring (AI)',
        ft = 'python',
      },

      -- select ollama model
      {
        '<leader>om',
        ':OllamaModel<cr>',
        desc = 'ollama select model',
        mode = { 'n', 'v' },
      },
    },

    ---@type Ollama.Config
    opts = {
      -- your configuration overrides
      model = ollama_model,
      url = ollama_url,
      -- Ollama.app already runs the server; starting another one here would
      -- shadow it, and the pkill stop command would also kill the app's server.
      serve = {
        on_start = false,
      },
    },
  },

  -- Claude Code integration
  {
    'coder/claudecode.nvim',
    cmd = { 'ClaudeCode' },
    keys = {
      {
        '<leader>cc',
        '<cmd>ClaudeCode<cr>',
        desc = 'Open Claude Code',
      },
    },
    opts = {
      -- Optional: configure working directory
      -- cwd = vim.fn.getcwd(),

      -- Optional: configure terminal behavior
      -- Use snacks.nvim for enhanced terminal if available
      use_snacks = true,

      -- Terminal configuration
      terminal = {
        -- Split direction: 'horizontal', 'vertical', 'float'
        split = 'horizontal',
        -- Size of the split (0.0 to 1.0 for percentage, >1 for fixed size)
        size = 0.4,
        -- Close terminal when claude exits
        close_on_exit = true,
      },
    },
    dependencies = {
      'folke/snacks.nvim', -- Optional: for enhanced terminal support
    },
  },
}

