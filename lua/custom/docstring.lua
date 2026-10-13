-- AI-written reST (Sphinx) docstrings for Python, inserted without touching code.
--
-- The model only returns docstring text. This module finds the function/class
-- under the cursor with treesitter and inserts (or replaces) the docstring
-- itself, so the model can never edit or delete code.
local M = {}

local SYSTEM_PROMPT = table.concat({
  'You write Python docstrings in reStructuredText (Sphinx) style.',
  'Follow PEP 257: a summary line of at most 72 characters in the imperative mood',
  '("Return ...", not "Returns ..."), ending in a period; then a blank line and the fields.',
  'Give every parameter a :param name: line and a :type name: line.',
  'Add :raises Exc: only for exceptions the code explicitly raises, and :return: plus :rtype:',
  'if it returns a value.',
  'Never document self or cls. For a class, describe the class and its __init__ parameters.',
  'Reply with ONLY the docstring text: no triple quotes, no code fences, no code, no commentary.',
}, ' ')

local DEF_TYPES = { function_definition = true, class_definition = true }

--- Strip code fences, quotes, and surrounding blank lines from the model reply.
---@param text string
---@return string[]
local function clean(text)
  text = text:gsub('<think>.-</think>', '')
  text = text:gsub('^%s*```%w*\n', ''):gsub('\n```%s*$', '')
  text = vim.trim(text)
  text = text:gsub('^[rRuU]?"""', ''):gsub('"""$', ''):gsub("^'''", ''):gsub("'''$", '')
  local lines = vim.split(vim.trim(text), '\n', { plain = true })
  -- Drop the model's own indentation; we re-indent to match the body
  local min_indent
  for i = 2, #lines do
    if lines[i]:match '%S' then
      local n = #lines[i]:match '^%s*'
      min_indent = math.min(min_indent or n, n)
    end
  end
  for i = 2, #lines do
    lines[i] = lines[i]:sub((min_indent or 0) + 1):gsub('%s+$', '')
  end
  return lines
end

--- Names of type-hinted parameters, and whether the return type is hinted.
---@param def TSNode function_definition
---@param buf integer
---@return table<string, boolean>, boolean
local function hinted(def, buf)
  local names = {}
  local params = def:field('parameters')[1]
  for child in (params and params:iter_children() or function() end) do
    if child:type() == 'typed_parameter' or child:type() == 'typed_default_parameter' then
      local id = child:field('name')[1] or child:named_child(0)
      if id then
        -- *args / **kwargs wrap the identifier in a splat node
        names[(vim.treesitter.get_node_text(id, buf):gsub('^%*+', ''))] = true
      end
    end
  end
  return names, def:field('return_type')[1] ~= nil
end

--- Remove :type:/:rtype: fields (and their continuation lines) the signature already covers.
--- Sphinx reads hints from the signature, so repeating them is redundant.
---@param lines string[]
---@param names table<string, boolean>
---@param has_return boolean
---@return string[]
local function drop_hinted_fields(lines, names, has_return)
  local out, skipping = {}, false
  for _, line in ipairs(lines) do
    local field = line:match '^:type%s+%*?%*?([%w_]+):'
    if (field and names[field]) or (has_return and line:match '^:rtype:') then
      skipping = true
    elseif skipping and line:match '^%s+%S' then
      -- continuation of the dropped field
    else
      skipping = false
      table.insert(out, line)
    end
  end
  -- A blank line before the fields can be left dangling at the end
  while #out > 1 and out[#out] == '' do
    table.remove(out)
  end
  return out
end

--- Source sent to the model. For a class, only the header and __init__: the
--- full class makes the model summarize every method into the class docstring.
---@param node TSNode function_definition or class_definition
---@param buf integer
---@return string
local function source_for(node, buf)
  local outer = node:parent():type() == 'decorated_definition' and node:parent() or node
  if node:type() ~= 'class_definition' then
    return vim.treesitter.get_node_text(outer, buf)
  end
  local outer_row = outer:range()
  local body_row = node:field('body')[1]:range()
  local parts = { table.concat(vim.api.nvim_buf_get_lines(buf, outer_row, body_row, false), '\n') }
  for child in node:field('body')[1]:iter_children() do
    local def = child:type() == 'decorated_definition' and child:field('definition')[1] or child
    if def:type() == 'function_definition' and vim.treesitter.get_node_text(def:field('name')[1], buf) == '__init__' then
      -- Re-indent: get_node_text drops the first line's leading whitespace
      local _, col = child:range()
      table.insert(parts, string.rep(' ', col) .. vim.treesitter.get_node_text(child, buf))
    end
  end
  if #parts == 1 then
    table.insert(parts, '    ...')
  end
  return table.concat(parts, '\n')
end

--- Build the docstring lines at the given indent.
---@param lines string[]
---@param indent string
---@return string[]
local function format(lines, indent)
  if #lines == 1 then
    return { indent .. '"""' .. lines[1] .. '"""' }
  end
  -- PEP 257: a blank line separates the summary from the rest
  if lines[2] ~= '' then
    table.insert(lines, 2, '')
  end
  local out = { indent .. '"""' .. lines[1] }
  for i = 2, #lines do
    table.insert(out, lines[i] == '' and '' or indent .. lines[i])
  end
  table.insert(out, indent .. '"""')
  return out
end

---@param opts { url: string, model: string }
function M.generate(opts)
  local buf = vim.api.nvim_get_current_buf()
  local node = vim.treesitter.get_node()
  while node and not DEF_TYPES[node:type()] do
    node = node:parent()
  end
  if not node then
    vim.notify('No function or class under the cursor', vim.log.levels.WARN)
    return
  end
  local body = node:field('body')[1]
  local def_row = node:range()
  local body_row, body_col = body:range()
  if body_row == def_row then
    vim.notify('One-line definitions are not supported', vim.log.levels.WARN)
    return
  end

  -- Existing docstring = first statement of the body if it is a bare string
  local replace_end_row
  local first = body:named_child(0)
  if first and first:type() == 'expression_statement' then
    local s = first:named_child(0)
    if s and s:type() == 'string' then
      replace_end_row = select(3, first:range())
    end
  end

  -- Extmarks track the insertion point if the buffer is edited while waiting
  local ns = vim.api.nvim_create_namespace 'custom_docstring'
  local mark = vim.api.nvim_buf_set_extmark(buf, ns, body_row, 0, {
    end_row = replace_end_row and replace_end_row + 1 or nil,
    end_col = replace_end_row and 0 or nil,
    strict = false, -- a docstring on the file's last line ends past the buffer
  })

  local indent = string.rep(' ', body_col)
  local code = source_for(node, buf)
  local name = vim.treesitter.get_node_text(node:field('name')[1], buf)
  -- Read before the request: treesitter nodes go stale once the buffer changes
  local hint_names, has_return_hint
  if node:type() == 'function_definition' then
    hint_names, has_return_hint = hinted(node, buf)
  end

  vim.notify('Writing docstring for ' .. name .. '…')
  local payload = vim.json.encode {
    model = opts.model,
    stream = false,
    options = { temperature = 0.2 },
    messages = {
      { role = 'system', content = SYSTEM_PROMPT },
      { role = 'user', content = 'Write the docstring for this code:\n\n```python\n' .. code .. '\n```' },
    },
  }
  vim.system(
    { 'curl', '-sS', '-m', '300', opts.url .. '/api/chat', '-H', 'Content-Type: application/json', '--data-binary', '@-' },
    { stdin = payload, text = true },
    vim.schedule_wrap(function(res)
      local pos = vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_extmark_by_id(buf, ns, mark, { details = true })
      if pos and #pos > 0 then
        vim.api.nvim_buf_del_extmark(buf, ns, mark)
      end
      if not pos or #pos == 0 then
        return
      end
      local ok, reply = pcall(vim.json.decode, res.stdout or '')
      if res.code ~= 0 or not ok or not reply.message then
        local err = ok and reply and reply.error or res.stderr or 'no response'
        vim.notify('Docstring failed: ' .. vim.trim(tostring(err)), vim.log.levels.ERROR)
        return
      end
      local lines = clean(reply.message.content or '')
      if hint_names then
        lines = drop_hinted_fields(lines, hint_names, has_return_hint)
      end
      if #lines == 0 or lines[1] == '' then
        vim.notify('Docstring failed: empty reply from ' .. opts.model, vim.log.levels.ERROR)
        return
      end
      local start_row = pos[1]
      local end_row = pos[3].end_row or start_row
      vim.api.nvim_buf_set_lines(buf, start_row, end_row, false, format(lines, indent))
      vim.notify('Docstring added to ' .. name)
    end)
  )
end

return M
