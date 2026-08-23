-- coding_dojo -- an interactive path to expert-level code.
-- Local checkout, not a git remote, so lazy loads it from `dir`.
return {
  {
    dir = vim.fn.expand '~/github_repos/coding_dojo',
    cmd = 'Dojo',
    opts = {
      -- Mason has pyright, not basedpyright. Attached to dojo work buffers
      -- only, so this does not turn Python LSP on globally (lsp.lua leaves
      -- `pyright` commented out on purpose).
      lsp = { 'ruff', 'pyright' },

      -- maplocalleader is <Space>, the same as mapleader, so the plugin's
      -- default single-character <localleader> maps would shadow the global
      -- <leader>s and <leader>t prefixes inside dojo buffers -- <Space>s would
      -- fire the lesson picker instead of waiting for the telescope key.
      -- Namespaced under <leader>d instead; which-key picks these up.
      keymaps = {
        run = '<leader>dr',
        test = '<leader>dt',
        review = '<leader>dm',
        ask = '<leader>da',
        lint = '<leader>dl',
        next = '<leader>dn',
        prev = '<leader>dp',
        ladder = '<leader>ds',
        reset = '<leader>dR',
      },
    },
    config = function(_, opts)
      require('dojo').setup(opts)
    end,
  },
}
