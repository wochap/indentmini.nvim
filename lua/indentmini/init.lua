local api, UP, DOWN, INVALID = vim.api, -1, 1, -1
local buf_set_extmark, set_provider = api.nvim_buf_set_extmark, api.nvim_set_decoration_provider
local ns = api.nvim_create_namespace('IndentLine')
local ffi = require('ffi')
local opt = {
  only_current = false,
  config = {
    virt_text_pos = 'overlay',
    hl_mode = 'combine',
    ephemeral = true,
  },
}
local enabled = true

ffi.cdef([[
  typedef struct {} Error;
  typedef int colnr_T;
  typedef struct window_S win_T;
  typedef struct file_buffer buf_T;
  buf_T *find_buffer_by_handle(int buffer, Error *err);
  int get_sw_value(buf_T *buf);
  typedef int32_t linenr_T;
  int get_indent_lnum(linenr_T lnum);
  char *ml_get(linenr_T lnum);
]])
local C = ffi.C
local ml_get = C.ml_get
local find_buffer_by_handle = C.find_buffer_by_handle
local get_sw_value, get_indent_lnum = C.get_sw_value, C.get_indent_lnum

--- @class Snapshot
--- @field indent? integer
--- @field is_empty? boolean
--- @field is_tab? boolean
--- @field indent_cols? integer
--- @field line_text? string

--- @class Context
--- @field snapshot table<integer, Snapshot>
--- @field changedtick integer
--- @field wrap_state? table
local context = { snapshot = {}, changedtick = INVALID }

--- check text only has space or tab see bench/space_or_tab.lua
--- @param text string
--- @return boolean true only have space or tab
local function only_spaces_or_tabs(text)
  for i = 1, #text do
    local byte = string.byte(text, i)
    if byte ~= 32 and byte ~= 9 then -- 32 is space, 9 is tab
      return false
    end
  end
  return true
end

--- @param bufnr integer
--- @return integer the shiftwidth value of bufnr
local function get_shiftw_value(bufnr)
  local handle = find_buffer_by_handle(bufnr, ffi.new('Error'))
  return get_sw_value(handle)
end

--- store the line data in snapshot and update the blank line indent
--- @param lnum integer
--- @return Snapshot
local function make_snapshot(lnum)
  local line_text = ffi.string(ml_get(lnum))
  local is_empty = #line_text == 0 or only_spaces_or_tabs(line_text)
  local indent = is_empty and 0 or get_indent_lnum(lnum)
  if is_empty then
    local prev_lnum = lnum - 1
    while prev_lnum >= 1 do
      local sp = context.snapshot[prev_lnum] or make_snapshot(prev_lnum)
      if (not sp.is_empty and sp.indent == 0) or (sp.indent > 0) then
        if sp.indent > 0 then
          indent = sp.indent
        end
        break
      end
      prev_lnum = prev_lnum - 1
    end
  end

  local prev = context.snapshot[lnum - 1]
  if prev and prev.is_empty and prev.indent < indent then
    local prev_lnum = lnum - 1
    while prev_lnum >= 1 do
      local sp = context.snapshot[prev_lnum]
      if not sp or not sp.is_empty or sp.indent >= indent then
        break
      end
      sp.indent = indent
      sp.indent_cols = indent
      prev_lnum = prev_lnum - 1
    end
  end
  local indent_cols = line_text:find('[^ \t]')
  indent_cols = indent_cols and indent_cols - 1 or INVALID
  if is_empty then
    indent_cols = indent
  end
  local snapshot = {
    indent = indent,
    is_empty = is_empty,
    indent_cols = indent_cols,
  }

  context.snapshot[lnum] = snapshot
  return snapshot
end

--- @param lnum integer
--- @return Snapshot
local function find_in_snapshot(lnum)
  context.snapshot[lnum] = context.snapshot[lnum] or make_snapshot(lnum)
  return context.snapshot[lnum]
end

--- @param row integer
--- @param direction integer UP or DOWN
--- @return integer
--- @return integer
local function range_in_snapshot(row, direction, fn)
  while row >= 0 and row < context.count do
    local sp = find_in_snapshot(row + 1)
    if fn(sp.indent, sp.is_empty, row) then
      return sp.indent, row
    end
    row = row + direction
  end
  return INVALID, INVALID
end

local function out_current_range(row)
  return opt.only_current
    and context.range_srow
    and context.range_erow
    and (row < context.range_srow or row > context.range_erow)
end

local function find_current_range(currow_indent)
  local curlevel = math.ceil(currow_indent / context.tabstop) -- for mixup
  local range_fn = function(indent, empty, row)
    local level = math.ceil(indent / context.tabstop)
    if
      ((not empty and not context.mixup) and indent < currow_indent)
      or (context.mixup and level < curlevel)
    then
      if row < context.currow then
        context.range_srow = row
      else
        context.range_erow = row
      end
      return true
    end
  end
  range_in_snapshot(context.currow - 1, UP, range_fn)
  range_in_snapshot(context.currow + 1, DOWN, range_fn)
  if context.range_srow and not context.range_erow then
    context.range_erow = context.count - 1
  end
  context.cur_inlevel = context.mixup and math.ceil(currow_indent / context.tabstop)
    or math.floor(currow_indent / context.step)
end

local function on_line(_, _, bufnr, row)
  if not enabled then
    return
  end
  local sp = find_in_snapshot(row + 1)
  if sp.indent == 0 or out_current_range(row) then
    return
  end
  if context.wrap_state[row] ~= nil then
    context.wrap_state[row] = true
  end
  local currow_insert = api.nvim_get_mode().mode == 'i' and context.currow == row
  -- mixup like vim code has modeline vi:set ts=8 sts=4 sw=4 noet:
  -- 4 8 12 16 20 24
  -- 1 1 2  2  3  3
  local total = context.mixup and math.ceil(sp.indent / context.tabstop) or sp.indent - 1
  local step = context.mixup and 1 or context.step
  for i = 1, total, step do
    local col = i - 1
    local level = context.mixup and i or math.floor(col / context.step) + 1
    if context.is_tab and not context.mixup then
      col = level - 1
    end
    if
      col >= context.leftcol
      and level >= opt.minlevel
      and (not opt.only_current or level == context.cur_inlevel)
      and col < sp.indent_cols
      and (not currow_insert or col ~= context.curcol)
    then
      local row_in_curblock = context.range_srow
        and (row > context.range_srow and row < context.range_erow)
      local higroup = row_in_curblock and level == context.cur_inlevel and 'IndentLineCurrent'
        or 'IndentLine'
      if opt.only_current and row_in_curblock and level ~= context.cur_inlevel then
        higroup = 'IndentLineCurHide'
      end
      opt.config.virt_text[1][2] = higroup
      if sp.is_empty and col > 0 then
        opt.config.virt_text_win_col = not context.mixup and i - 1 - context.leftcol
          or (i - 1) * context.tabstop
      end
      buf_set_extmark(bufnr, ns, row, col, opt.config)
      opt.config.virt_text_win_col = nil
    end
  end
end

local function on_win(_, winid, bufnr, toprow, botrow)
  local is_im_enabled_ok, is_im_enabled = pcall(vim.api.nvim_buf_get_var, bufnr, 'is_im_enabled')
  if is_im_enabled_ok and not is_im_enabled then
    return false
  end
  if
    bufnr ~= api.nvim_get_current_buf()
    or vim.iter(opt.exclude):find(function(v)
      return v == vim.bo[bufnr].ft or v == vim.bo[bufnr].buftype
    end)
    or not enabled
  then
    return false
  end
  opt.config.virt_text_repeat_linebreak = vim.wo[winid].wrap and vim.wo[winid].breakindent
  local changedtick = api.nvim_buf_get_changedtick(bufnr)
  if changedtick ~= context.changedtick then
    context = { snapshot = {}, changedtick = changedtick }
  end
  context.is_tab = not vim.bo[bufnr].expandtab
  context.step = get_shiftw_value(bufnr)
  context.tabstop = vim.bo[bufnr].tabstop
  context.softtabstop = vim.bo[bufnr].softtabstop
  context.win_width = api.nvim_win_get_width(winid)
  context.mixup = context.is_tab and context.tabstop > context.softtabstop
  for i = toprow, botrow do
    context.snapshot[i + 1] = make_snapshot(i + 1)
  end
  api.nvim_win_set_hl_ns(winid, ns)
  context.leftcol = vim.fn.winsaveview().leftcol
  context.count = api.nvim_buf_line_count(bufnr)
  local pos = api.nvim_win_get_cursor(winid)
  context.currow = pos[1] - 1
  context.curcol = pos[2]
  context.botrow = botrow
  context.wrap_state = {}
  local currow_indent = find_in_snapshot(context.currow + 1).indent
  find_current_range(currow_indent)
end

return {
  setup = function(conf)
    conf = conf or {}
    opt.only_current = conf.only_current or false
    opt.exclude = { 'dashboard', 'lazy', 'help', 'nofile', 'terminal', 'prompt' }
    vim.list_extend(opt.exclude, conf.exclude or {})
    opt.config.virt_text = { { conf.char or '│' } }
    opt.minlevel = conf.minlevel or 1
    set_provider(ns, { on_win = on_win, on_line = on_line })
    if opt.only_current and vim.opt.cursorline then
      local bg = api.nvim_get_hl(0, { name = 'CursorLine' }).bg
      api.nvim_set_hl(0, 'IndentLineCurHide', { fg = bg })
    end
  end,
  toggle = function(state)
    if state ~= nil then
      enabled = state
    else
      enabled = not enabled
    end
  end,
  toggle_buff = function(bufnr, state)
    if bufnr == nil then
      bufnr = 0
    end
    local is_im_enabled_ok, is_im_enabled = pcall(vim.api.nvim_buf_get_var, bufnr, 'is_im_enabled')
    if state == nil then
      if is_im_enabled_ok then
        state = not is_im_enabled
      else
        state = false
      end
    end
    vim.api.nvim_buf_set_var(bufnr, 'is_im_enabled', state)
  end,
}
