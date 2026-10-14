-- AI-written reST (Sphinx) docstrings for Python, inserted without touching code.
--
-- Treesitter supplies the facts (parameters, type hints, raised exceptions,
-- whether a value is returned). The model only fills in descriptions as JSON,
-- constrained by a schema, and this module assembles the reST itself. So the
-- style is fixed by code, and the model can never edit or delete code.
local M = {}

local SYSTEM_PROMPT = table.concat({
  'You document Python functions and classes.',
  'summary: one line, at most 72 characters, imperative mood ("Return ...", not "Returns ..."), ending in a period.',
  'description: extra detail only if the summary is not enough, otherwise an empty string.',
  'params, raises, returns: describe exactly the items listed in the request, each in one short phrase.',
  'type: a concise Python type such as str, int, list[str], dict, or "int or None".',
  'For a class, describe the class; its params are the __init__ parameters.',
  'The request may include project context: imports, called functions with their docstrings,',
  'and call sites. Use it to get types and meaning right, but only document the given code.',
  'Do not invent behavior that the code and context do not show.',
}, ' ')

-- Ollama structured output: the reply must match this JSON schema
local SCHEMA = {
  type = 'object',
  properties = {
    summary = { type = 'string' },
    description = { type = 'string' },
    params = {
      type = 'array',
      items = {
        type = 'object',
        properties = { name = { type = 'string' }, type = { type = 'string' }, description = { type = 'string' } },
        required = { 'name', 'type', 'description' },
      },
    },
    raises = {
      type = 'array',
      items = {
        type = 'object',
        properties = { exception = { type = 'string' }, description = { type = 'string' } },
        required = { 'exception', 'description' },
      },
    },
    returns = {
      type = 'object',
      properties = { type = { type = 'string' }, description = { type = 'string' } },
      required = { 'type', 'description' },
    },
  },
  required = { 'summary', 'description', 'params', 'raises', 'returns' },
}

local MAX_WIDTH = 79
local DEF_TYPES = { function_definition = true, class_definition = true }
local SCOPE_TYPES = { function_definition = true, class_definition = true, lambda = true }

local function text(node, buf)
  return vim.treesitter.get_node_text(node, buf)
end

--- Parameters of a function_definition, in order, without self/cls.
---@return { name: string, hinted: boolean }[]
local function params_of(def, buf)
  local out = {}
  local params = def:field('parameters')[1]
  if not params then
    return out
  end
  for p in params:iter_children() do
    local t, id = p:type(), nil
    if t == 'identifier' then
      id = p
    elseif t == 'default_parameter' or t == 'typed_default_parameter' then
      id = p:field('name')[1]
    elseif t == 'typed_parameter' or t == 'list_splat_pattern' or t == 'dictionary_splat_pattern' then
      id = p:named_child(0)
    end
    if id then
      -- typed *args / **kwargs: the identifier sits inside the splat pattern
      if id:type() == 'list_splat_pattern' or id:type() == 'dictionary_splat_pattern' then
        id = id:named_child(0)
      end
      local name = text(id, buf)
      if not (#out == 0 and (name == 'self' or name == 'cls')) then
        table.insert(out, { name = name, hinted = t == 'typed_parameter' or t == 'typed_default_parameter' })
      end
    end
  end
  return out
end

--- Walk a definition's body without descending into nested functions/classes.
local function each_in_scope(node, fn)
  for child in node:iter_children() do
    fn(child)
    if not SCOPE_TYPES[child:type()] then
      each_in_scope(child, fn)
    end
  end
end

--- Exception names raised explicitly in the body, and whether a value is returned.
---@return string[], boolean
local function raises_and_returns(def, buf)
  local raises, seen, returns = {}, {}, false
  each_in_scope(def:field('body')[1], function(n)
    if n:type() == 'return_statement' and n:named_child_count() > 0 then
      returns = true
    elseif n:type() == 'raise_statement' then
      local exc = n:named_child(0)
      if exc and exc:type() == 'call' then
        exc = exc:field('function')[1]
      end
      -- Bare `raise` and `raise err` (a variable) have no class name to document
      if exc and (exc:type() == 'identifier' or exc:type() == 'attribute') then
        local name = text(exc, buf)
        if name:match '^[%u]' or name:match '%.[%u][%w_]*$' then
          if not seen[name] then
            seen[name] = true
            table.insert(raises, name)
          end
        end
      end
    end
  end)
  return raises, returns
end

--- The __init__ of a class body, if any.
local function init_of(class, buf)
  for child in class:field('body')[1]:iter_children() do
    local def = child:type() == 'decorated_definition' and child:field('definition')[1] or child
    if def:type() == 'function_definition' and text(def:field('name')[1], buf) == '__init__' then
      return def, child
    end
  end
end

--- Source sent to the model. For a class, only the header and __init__: the
--- full class makes the model summarize every method into the class docstring.
local function source_for(node, buf)
  local outer = node:parent():type() == 'decorated_definition' and node:parent() or node
  if node:type() ~= 'class_definition' then
    return text(outer, buf)
  end
  local outer_row = outer:range()
  local body_row = node:field('body')[1]:range()
  local parts = { table.concat(vim.api.nvim_buf_get_lines(buf, outer_row, body_row, false), '\n') }
  local _, init_outer = init_of(node, buf)
  if init_outer then
    -- Re-indent: get_node_text drops the first line's leading whitespace
    local _, col = init_outer:range()
    table.insert(parts, string.rep(' ', col) .. text(init_outer, buf))
  else
    table.insert(parts, '    ...')
  end
  return table.concat(parts, '\n')
end

--- Word-wrap `s` to `width`, prefixing the first line and indenting the rest.
local function wrap(s, width, first_prefix, cont_prefix)
  local lines, line = {}, first_prefix
  for word in s:gmatch '%S+' do
    if line ~= first_prefix and line ~= cont_prefix and #line + 1 + #word > width then
      table.insert(lines, line)
      line = cont_prefix .. word
    else
      line = (line == first_prefix or line == cont_prefix) and line .. word or line .. ' ' .. word
    end
  end
  table.insert(lines, line)
  return lines
end

local function one_line(s)
  return vim.trim((s or ''):gsub('%s+', ' '))
end

--- Assemble the docstring body (without quotes or indentation).
---@param facts { params: { name: string, hinted: boolean }[], raises: string[], returns: boolean, return_hinted: boolean }
---@param reply table decoded model JSON
---@param width integer available width after indentation
---@return string[]
local function build(facts, reply, width)
  local by_name = {}
  for _, p in ipairs(reply.params or {}) do
    if type(p) == 'table' and p.name then
      by_name[(tostring(p.name):gsub('^%*+', ''))] = p
    end
  end
  local exc_desc = {}
  for _, r in ipairs(reply.raises or {}) do
    if type(r) == 'table' and r.exception then
      exc_desc[tostring(r.exception)] = r.description
    end
  end

  local summary = one_line(reply.summary)
  if summary ~= '' and not summary:match '[%.!?]$' then
    summary = summary .. '.'
  end
  local lines = { summary }

  local description = vim.trim(reply.description or '')
  if description ~= '' then
    for para in (description .. '\n\n'):gmatch '(.-)\n%s*\n' do
      if vim.trim(para) ~= '' then
        table.insert(lines, '')
        vim.list_extend(lines, wrap(para, width, '', ''))
      end
    end
  end

  local fields = {}
  local function field(prefix, body)
    vim.list_extend(fields, wrap(one_line(body), width, prefix, '    '))
  end
  for _, p in ipairs(facts.params) do
    local d = by_name[p.name] or {}
    field(':param ' .. p.name .. ': ', d.description)
    if not p.hinted and one_line(d.type) ~= '' then
      field(':type ' .. p.name .. ': ', d.type)
    end
  end
  for _, exc in ipairs(facts.raises) do
    field(':raises ' .. exc .. ': ', exc_desc[exc] or exc_desc[exc:match '[%w_]+$'])
  end
  if facts.returns then
    local r = type(reply.returns) == 'table' and reply.returns or {}
    field(':return: ', r.description)
    if not facts.return_hinted and one_line(r.type) ~= '' then
      field(':rtype: ', r.type)
    end
  end
  if #fields > 0 then
    table.insert(lines, '')
    vim.list_extend(lines, fields)
  end
  for i, l in ipairs(lines) do
    lines[i] = l:gsub('%s+$', '')
  end
  return lines
end

--- Wrap the docstring body in quotes at the given indent.
local function format(lines, indent)
  if #lines == 1 then
    return { indent .. '"""' .. lines[1] .. '"""' }
  end
  local out = { indent .. '"""' .. lines[1] }
  for i = 2, #lines do
    table.insert(out, lines[i] == '' and '' or indent .. lines[i])
  end
  table.insert(out, indent .. '"""')
  return out
end

--- Innermost function/class at the cursor. Starting from the first non-blank
--- character keeps a nested def from resolving to its enclosing function.
local function definition_at_cursor()
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  local first = vim.api.nvim_get_current_line():find '%S'
  if first and col < first - 1 then
    col = first - 1
  end
  local node = vim.treesitter.get_node { pos = { row - 1, col } }
  while node and not DEF_TYPES[node:type()] do
    node = node:parent()
  end
  return node
end

local send -- defined below generate, which hands off to it

---@param opts { url: string, model: string }
function M.generate(opts)
  local buf = vim.api.nvim_get_current_buf()
  local node = definition_at_cursor()
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

  -- Gather facts now: treesitter nodes go stale once the buffer changes
  local name = text(node:field('name')[1], buf)
  local facts = { params = {}, raises = {}, returns = false, return_hinted = false }
  local def = node:type() == 'class_definition' and init_of(node, buf) or node
  if def then
    facts.params = params_of(def, buf)
    facts.raises, facts.returns = raises_and_returns(def, buf)
    facts.return_hinted = def:field('return_type')[1] ~= nil
  end
  if node:type() == 'class_definition' then
    facts.returns = false
  end

  -- Extmarks track the insertion point if the buffer is edited while waiting
  local ns = vim.api.nvim_create_namespace 'custom_docstring'
  local mark = vim.api.nvim_buf_set_extmark(buf, ns, body_row, 0, {
    end_row = replace_end_row and replace_end_row + 1 or nil,
    end_col = replace_end_row and 0 or nil,
    strict = false, -- a docstring on the file's last line ends past the buffer
  })

  local function names(list, key)
    local out = vim.tbl_map(function(x)
      return key and x[key] or x
    end, list)
    return #out > 0 and table.concat(out, ', ') or 'none'
  end
  local source = source_for(node, buf)

  vim.notify('Writing docstring for ' .. name .. '…')
  require('custom.docstring_context').gather(buf, node, function(context)
    local request = table.concat({
      'Code to document:',
      '```python',
      source,
      '```',
      '',
      'params to describe: ' .. names(facts.params, 'name'),
      'raises to describe: ' .. names(facts.raises),
      'returns: ' .. (facts.returns and 'describe the return value' or 'none, leave description and type empty'),
    }, '\n')
    if context ~= '' then
      request = request .. '\n\nProject context (for understanding only, do not document it):\n```python\n' .. context .. '\n```'
    end
    send(opts, buf, ns, mark, facts, name, body_col, request)
  end)
end

--- Ask the model for the descriptions and insert the assembled docstring.
function send(opts, buf, ns, mark, facts, name, body_col, request)
  local payload = vim.json.encode {
    model = opts.model,
    stream = false,
    format = SCHEMA,
    options = { temperature = 0.2 },
    messages = {
      { role = 'system', content = SYSTEM_PROMPT },
      { role = 'user', content = request },
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
      local ok_doc, doc = pcall(vim.json.decode, reply.message.content or '', { luanil = { object = true, array = true } })
      if not ok_doc or type(doc) ~= 'table' or one_line(doc.summary) == '' then
        vim.notify('Docstring failed: unusable reply from ' .. opts.model, vim.log.levels.ERROR)
        return
      end
      local lines = build(facts, doc, MAX_WIDTH - body_col)
      vim.api.nvim_buf_set_lines(buf, pos[1], pos[3].end_row or pos[1], false, format(lines, string.rep(' ', body_col)))
      vim.notify('Docstring added to ' .. name)
    end)
  )
end

return M
