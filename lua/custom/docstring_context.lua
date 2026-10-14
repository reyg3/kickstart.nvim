-- Project context for custom.docstring: what the code being documented uses
-- and how it is used, so the model can describe types and meaning accurately.
--
-- Same file (treesitter): imports, module-level names, and the enclosing class.
-- Whole project (LSP, e.g. pyright): signatures and docstrings of called
-- functions/classes, and a few call sites of the definition itself. Without an
-- LSP, called names fall back to definitions in the same file.
local M = {}

local MAX_CALLS = 12 -- distinct called names to look up
local MAX_CALLERS = 3 -- example call sites to include
local MAX_DOC_LINES = 12 -- per called definition's docstring
local MAX_CHARS = 8000 -- total context budget
local LSP_TIMEOUT_MS = 3000 -- never hold up the docstring longer than this

local DEF_TYPES = { function_definition = true, class_definition = true }

local function text(node, src)
  return vim.treesitter.get_node_text(node, src)
end

--- Stdlib stubs and installed packages: large, and rarely what the code means.
local function is_external(path)
  return path:find '/site%-packages/'
    or path:find '/dist%-packages/'
    or path:find 'typeshed'
    or path:find '%.pyi$'
    or path:find '/%.venv/'
    or path:find '/lib/python%d'
end

local function display_path(path)
  return vim.fn.fnamemodify(path, ':~:.')
end

local source_cache = {}

--- Full source of a file, preferring the live buffer if it is loaded.
local function read_source(path)
  local b = vim.fn.bufnr(path)
  if b ~= -1 and vim.api.nvim_buf_is_loaded(b) then
    return table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), '\n')
  end
  if source_cache[path] == nil then
    local f = io.open(path, 'r')
    source_cache[path] = f and f:read '*a' or false
    if f then
      f:close()
    end
  end
  return source_cache[path] or nil
end

local function first_lines(s, n)
  local lines = vim.split(s, '\n', { plain = true })
  if #lines > n then
    lines = vim.list_slice(lines, 1, n)
    table.insert(lines, '    ...')
  end
  return table.concat(lines, '\n')
end

--- Docstring node of a definition, if its body starts with a bare string.
local function docstring_of(def)
  local body = def:field('body')[1]
  local first = body and body:named_child(0)
  if first and first:type() == 'expression_statement' and first:named_child(0) and first:named_child(0):type() == 'string' then
    return first
  end
end

--- `def name(...) -> T:` (with decorators) plus its docstring, or `...`.
local function signature_and_doc(def, src)
  local outer = def:parent() and def:parent():type() == 'decorated_definition' and def:parent() or def
  local _, _, start_byte = outer:start()
  local _, _, body_byte = def:field('body')[1]:start()
  local _, indent = def:start()
  local sig = vim.trim(src:sub(start_byte + 1, body_byte))
  local doc = docstring_of(def)
  local pad = string.rep(' ', 4)
  -- Re-base continuation lines: the substring keeps their original indentation
  sig = sig:gsub('\n' .. string.rep(' ', indent), '\n')
  return sig .. '\n' .. pad .. (doc and first_lines(text(doc, src), MAX_DOC_LINES):gsub('\n' .. string.rep(' ', indent + 4), '\n' .. pad) or '...')
end

local function init_of(class, src)
  for child in class:field('body')[1]:iter_children() do
    local def = child:type() == 'decorated_definition' and child:field('definition')[1] or child
    if def:type() == 'function_definition' and text(def:field('name')[1], src) == '__init__' then
      return def
    end
  end
end

--- Summary of the definition at (row, col) in `src`: signature + docstring,
--- and for a class, its __init__ signature too.
local function def_summary(src, row, col)
  local ok, parser = pcall(vim.treesitter.get_string_parser, src, 'python')
  if not ok then
    return nil
  end
  local node = parser:parse()[1]:root():named_descendant_for_range(row, col, row, col)
  while node and not DEF_TYPES[node:type()] do
    node = node:parent()
  end
  if not node then
    return nil
  end
  local out = signature_and_doc(node, src)
  -- Name the owning class of a method, e.g. `# method of Store`
  local owner = node:parent()
  if owner and owner:type() == 'decorated_definition' then
    owner = owner:parent()
  end
  owner = owner and owner:parent()
  if owner and owner:type() == 'class_definition' then
    out = '# method of ' .. text(owner:field('name')[1], src) .. '\n' .. out
  end
  if node:type() == 'class_definition' then
    local init = init_of(node, src)
    if init then
      out = out .. '\n\n    ' .. signature_and_doc(init, src):gsub('\n', '\n    ')
    end
  end
  return out, node:range()
end

--- Imports and module-level assignments of the buffer.
local function module_context(buf, root)
  local imports, names = {}, {}
  for child in root:iter_children() do
    local t = child:type()
    if t == 'import_statement' or t == 'import_from_statement' or t == 'future_import_statement' then
      table.insert(imports, text(child, buf))
    elseif t == 'expression_statement' and child:named_child(0) and child:named_child(0):type() == 'assignment' then
      local s = text(child, buf):gsub('\n.*', ' ...')
      table.insert(names, #s > 160 and s:sub(1, 157) .. '...' or s)
    end
  end
  return imports, names
end

--- For a method, the enclosing class header and __init__ (what `self.x` is).
local function class_context(node, buf)
  local block = node:parent()
  if block and block:type() == 'decorated_definition' then
    block = block:parent()
  end
  local class = block and block:parent()
  if not class or class:type() ~= 'class_definition' then
    return nil
  end
  local header = vim.api.nvim_buf_get_lines(buf, class:range(), select(1, class:field('body')[1]:range()), false)
  local out = table.concat(header, '\n')
  local init = init_of(class, buf)
  if init and init ~= node then
    local _, col = init:start()
    out = out .. '\n' .. first_lines(string.rep(' ', col) .. text(init, buf), 40)
  end
  return out
end

--- Distinct calls made in `def`'s body: `foo(...)`, `obj.meth(...)`.
local function call_sites(def, buf)
  local sites, seen = {}, {}
  local function visit(n)
    for c in n:iter_children() do
      if c:type() == 'call' and #sites < MAX_CALLS then
        local f = c:field('function')[1]
        local id = f and f:type() == 'attribute' and f:field('attribute')[1] or f
        if id and id:type() == 'identifier' then
          local label = text(f, buf)
          if not seen[label] then
            seen[label] = true
            local row, col = id:range()
            table.insert(sites, { label = label, name = text(id, buf), row = row, col = col })
          end
        end
      end
      visit(c)
    end
  end
  visit(def:field('body')[1])
  return sites
end

--- Same-file definition by name, for when no LSP is attached.
local function find_local_def(root, buf, name)
  for child in root:iter_children() do
    local def = child:type() == 'decorated_definition' and child:field('definition')[1] or child
    if DEF_TYPES[def:type()] and text(def:field('name')[1], buf) == name then
      return def:field('name')[1]:range()
    end
  end
end

local function lsp_position(client, buf, row, col)
  local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ''
  return {
    textDocument = { uri = vim.uri_from_bufnr(buf) },
    position = { line = row, character = vim.str_utfindex(line, client.offset_encoding, col, false) },
  }
end

--- First location from a definition/references response list.
local function locations(results)
  local out = {}
  for _, r in pairs(results or {}) do
    local res = r.result
    if res and (res.uri or res.targetUri) then
      res = { res }
    end
    for _, loc in ipairs(res or {}) do
      local range = loc.targetSelectionRange or loc.range
      table.insert(out, { path = vim.uri_to_fname(loc.uri or loc.targetUri), row = range.start.line, col = range.start.character })
    end
  end
  return out
end

local function has_lsp(buf, method)
  return #vim.lsp.get_clients { bufnr = buf, method = method } > 0
end

-- LSP SymbolKind values worth describing: Class, Method, Function
local CALLABLE_KINDS = { [5] = true, [6] = true, [12] = true }

--- Project definitions named exactly `name`, via workspace/symbol. Used when
--- the receiver's type is unknown (untyped `obj.meth()`), so it is a guess.
local function lsp_symbol_matches(buf, name, cb)
  vim.lsp.buf_request_all(buf, 'workspace/symbol', { query = name }, function(results)
    local out = {}
    for _, r in pairs(results or {}) do
      for _, sym in ipairs(r.result or {}) do
        local loc = sym.location
        if sym.name == name and CALLABLE_KINDS[sym.kind] and loc and loc.range then
          local path = vim.uri_to_fname(loc.uri)
          if not is_external(path) then
            table.insert(out, { path = path, row = loc.range.start.line, col = loc.range.start.character })
          end
        end
      end
    end
    cb(out)
  end)
end

--- `path:line:` plus up to two preceding lines, so the model sees the
--- arguments' origins (e.g. `store = Store(...)` before `push(store)`).
local function call_snippet(src, path, row)
  local lines = vim.split(src, '\n', { plain = true })
  local out = {}
  for r = math.max(0, row - 2), row do
    local l = lines[r + 1]
    if l and vim.trim(l) ~= '' then
      table.insert(out, '    ' .. vim.trim(l))
    end
  end
  return display_path(path) .. ':' .. (row + 1) .. ':\n' .. table.concat(out, '\n')
end

--- Gather context for the definition `node` in `buf`, then call `cb(text)`.
--- All treesitter work on `buf` happens synchronously, before any LSP reply.
---@param buf integer
---@param node TSNode function_definition or class_definition
---@param cb fun(context: string)
function M.gather(buf, node, cb)
  source_cache = {}
  local root = node:tree():root()
  local cur_path = vim.api.nvim_buf_get_name(buf)
  local imports, names = module_context(buf, root)
  local class_ctx = node:type() == 'function_definition' and class_context(node, buf) or nil
  local target = node:type() == 'class_definition' and init_of(node, buf) or node
  local sites = target and call_sites(target, buf) or {}
  local start_row, _, end_row = node:range()
  local name_row, name_col = node:field('name')[1]:range()
  local buf_src = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n')

  local called, called_seen, callers = {}, {}, {}
  local pending, done = #sites + 1, false

  local function render()
    local parts = {}
    local function section(title, body)
      if body and body ~= '' then
        table.insert(parts, '# ' .. title .. '\n' .. body)
      end
    end
    section('Imports in this file', table.concat(imports, '\n'))
    section('Module-level names in this file', table.concat(names, '\n'))
    section('Enclosing class', class_ctx)
    local defs = {}
    for i = 1, #sites do
      if called[i] then
        table.insert(defs, '## ' .. called[i].label .. '  (' .. called[i].where .. ')\n' .. called[i].text)
      end
    end
    section('Functions and classes it calls', table.concat(defs, '\n\n'))
    section('Where it is called', table.concat(callers, '\n'))
    local out = table.concat(parts, '\n\n')
    if #out > MAX_CHARS then
      out = out:sub(1, MAX_CHARS) .. '\n# (context truncated)'
    end
    return out
  end

  local function finish()
    if not done then
      done = true
      cb(render())
    end
  end
  local function step()
    pending = pending - 1
    if pending == 0 then
      finish()
    end
  end
  vim.defer_fn(finish, LSP_TIMEOUT_MS)

  local function add_called(i, path, row, col, guessed)
    -- Skip the definition itself (recursion) and anything outside the project
    if not path or is_external(path) or (path == cur_path and row >= start_row and row <= end_row) then
      return
    end
    local src = path == cur_path and buf_src or read_source(path)
    local summary, def_row = nil, nil
    if src then
      summary, def_row = def_summary(src, row, col)
    end
    local key = path .. ':' .. tostring(def_row)
    if summary and not called_seen[key] then
      called_seen[key] = true
      local where = display_path(path) .. ':' .. (def_row + 1) .. (guessed and ', likely match by name' or '')
      called[i] = called[i] or { label = sites[i].label, where = where, text = '' }
      called[i].text = called[i].text == '' and summary or called[i].text .. '\n\n' .. summary
    end
  end

  local use_lsp = has_lsp(buf, 'textDocument/definition')
  for i, site in ipairs(sites) do
    if use_lsp then
      vim.lsp.buf_request_all(buf, 'textDocument/definition', function(client)
        return lsp_position(client, buf, site.row, site.col)
      end, function(results)
        if done then
          return
        end
        local loc = locations(results)[1]
        if loc then
          add_called(i, loc.path, loc.row, loc.col)
          step()
        elseif site.label:find '%.' and has_lsp(buf, 'workspace/symbol') then
          -- Untyped receiver: fall back to project definitions with this name,
          -- but only when the name is specific enough (one or two matches)
          lsp_symbol_matches(buf, site.name, function(matches)
            if not done and #matches > 0 and #matches <= 2 then
              for _, m in ipairs(matches) do
                add_called(i, m.path, m.row, m.col, true)
              end
            end
            step()
          end)
        else
          step()
        end
      end)
    else
      if not site.label:find '%.' or site.label:match '^self%.' then
        local row, col = find_local_def(root, buf, site.name)
        if row then
          add_called(i, cur_path, row, col)
        end
      end
      step()
    end
  end

  if has_lsp(buf, 'textDocument/references') then
    vim.lsp.buf_request_all(buf, 'textDocument/references', function(client)
      local p = lsp_position(client, buf, name_row, name_col)
      p.context = { includeDeclaration = false }
      return p
    end, function(results)
      if done then
        return
      end
      for _, loc in ipairs(locations(results)) do
        if #callers >= MAX_CALLERS then
          break
        end
        local inside = loc.path == cur_path and loc.row >= start_row and loc.row <= end_row
        if not inside and not is_external(loc.path) then
          local src = loc.path == cur_path and buf_src or read_source(loc.path)
          local line = src and vim.split(src, '\n', { plain = true })[loc.row + 1]
          -- References include `from x import name`; only real uses help
          if line and not vim.trim(line):match '^from%s' and not vim.trim(line):match '^import%s' then
            table.insert(callers, call_snippet(src, loc.path, loc.row))
          end
        end
      end
      step()
    end)
  else
    step()
  end
end

return M
