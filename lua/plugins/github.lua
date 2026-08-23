-- GitHub code review, without the browser
return {
  -- Full PR review workflow: conversations, inline comments, suggestions,
  -- approve/request-changes, reviewers, labels, CI checks.
  -- Requires the `gh` CLI, authenticated (`gh auth status`).
  {
    'pwntester/octo.nvim',
    cmd = 'Octo',
    dependencies = {
      'nvim-lua/plenary.nvim',
      'sindrets/diffview.nvim',
      'nvim-telescope/telescope.nvim',
      'nvim-tree/nvim-web-devicons',
    },
    opts = {
      picker = 'telescope',
      -- Silence the startup warning about the `read:project` gh scope,
      -- which is only needed for Projects v2 boards.
      suppress_missing_scope = { projects_v2 = true },
      mappings = {
        -- Octo defaults `focus_files`/`toggle_files` to <leader>e/<leader>b,
        -- which collide with Snacks explorer and the <leader>b buffer prefix.
        review_diff = {
          focus_files = { lhs = '<leader>pe', desc = 'focus changed-file panel' },
          toggle_files = { lhs = '<leader>pb', desc = 'toggle changed-file panel' },
        },
        file_panel = {
          focus_files = { lhs = '<leader>pe', desc = 'focus changed-file panel' },
          toggle_files = { lhs = '<leader>pb', desc = 'toggle changed-file panel' },
        },
      },
    },
    keys = {
      -- The review queue: this is the one that replaces the browser homepage.
      { '<leader>pS', '<cmd>Octo search is:pr is:open review-requested:@me<cr>', desc = 'PRs awaiting my review' },
      { '<leader>pl', '<cmd>Octo pr list<cr>', desc = 'PR list' },
      { '<leader>pr', '<cmd>Octo review start<cr>', desc = 'PR review start' },
      { '<leader>pR', '<cmd>Octo review resume<cr>', desc = 'PR review resume' },
      { '<leader>ps', '<cmd>Octo review submit<cr>', desc = 'PR review submit' },
      { '<leader>pd', '<cmd>Octo review discard<cr>', desc = 'PR review discard' },
      { '<leader>pk', '<cmd>Octo pr checks<cr>', desc = 'PR CI checks' },
      { '<leader>pi', '<cmd>Octo issue list<cr>', desc = 'Issue list' },
    },
  },

  -- Octo renders its review UI on top of diffview. Declaring it directly also
  -- gets you local, offline branch review: :DiffviewOpen origin/main...HEAD
  {
    'sindrets/diffview.nvim',
    cmd = { 'DiffviewOpen', 'DiffviewFileHistory', 'DiffviewClose' },
    opts = { enhanced_diff_hl = true },
    keys = {
      { '<leader>pv', '<cmd>DiffviewOpen origin/main...HEAD<cr>', desc = 'Diff branch vs origin/main' },
      { '<leader>pf', '<cmd>DiffviewFileHistory %<cr>', desc = 'File history' },
    },
  },
}
