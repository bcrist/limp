-- Predefined global variables:
-- file_path
-- comment_begin
-- comment_end
-- comment_line_prefix

-- Globals set just before processing each LIMP comment:
-- last_generated_data
-- base_indent
-- nl_style

local table = table
local debug = debug
local string = string
local tostring = tostring
local type = type
local select = select
local ipairs = ipairs
local dofile = dofile
local load = load
local getmetatable = getmetatable
local setmetatable = setmetatable

local fs = fs
local util = util

do -- strict.lua
   -- checks uses of undeclared global variables
   -- All global variables must be 'declared' through a regular assignment
   -- (even assigning nil will do) in a main chunk before being used
   -- anywhere or assigned to inside a function.
   local mt = getmetatable(_G)
   if mt == nil then
      mt = {}
      setmetatable(_G, mt)
   end

   __STRICT = true
   mt.__declared = {}

   mt.__newindex = function (t, n, v)
      if __STRICT and not mt.__declared[n] then
         local w = debug.getinfo(2, "S").what
         if w ~= "main" and w ~= "C" then
            error("assign to undeclared variable '"..n.."'", 2)
         end
         mt.__declared[n] = true
      end
      rawset(t, n, v)
   end
  
   mt.__index = function (t, n)
      if __STRICT and not mt.__declared[n] and debug.getinfo(2, "S").what ~= "C" then
         error("variable '"..n.."' is not declared", 2)
      end
      return rawget(t, n)
   end

   function global(...)
      for _, v in ipairs{...} do mt.__declared[v] = true end
   end

end

local function spairs_next(ctx, last)
   local next_index = nil
   if last == nil then
      next_index = 1
   elseif ctx.last_key == last then
      next_index = ctx.last_index + 1
   else
      for i = 1, #ctx.keys do
         if ctx.keys[i] == last then
            next_index = i + 1
         end
      end
   end

   local key = ctx.keys[next_index]
   ctx.last_index = next_index
   ctx.last_key = key

   if key ~= nil then
       return key, ctx.table[key]
   end
end

-- Identical to pairs() except guarantees sorted ordering using table.sort
function spairs(t, comp)
   local ordered_keys = {}
   for key in pairs(t) do
      table.insert(ordered_keys, key)
   end
   table.sort(ordered_keys, comp)
   return spairs_next, {
      table = t,
      keys = ordered_keys,
   }, nil
end


last_generated_data = nil
base_indent = nil
nl_style = nil
indent_size = 3
indent_char = ' '
limprc_path = nil
prefix = nil
postfix = nil
root_dir = nil

backtick = '`'

function trim_trailing_ws (str)
   return str:gsub('[ \t]+([\r\n])', '%1'):gsub('[ \t]+$', '')
end

function postprocess (str)
   return trim_trailing_ws(str)
end

do -- indent
   local current_indent = 0

   function get_indent ()
      local retval = ''
      if base_indent ~= nil and base_indent ~= '' then
         retval = base_indent
      end
      return retval .. string.rep(indent_char, current_indent * indent_size)
   end 

   function write_indent ()
      if base_indent ~= nil and base_indent ~= '' then
         write(base_indent)
      end
      local indent = string.rep(indent_char, current_indent * indent_size)
      if indent ~= '' then
         write(indent)
      end
   end

   function reset_indent ()
      current_indent = 0
   end

   function indent (count)
      if count == nil then count = 1 end
      current_indent = current_indent + count
   end

   function unindent (count)
      if count == nil then count = 1 end
      current_indent = current_indent - count
   end

   function set_indent (count)
      current_indent = count
   end

end

function normalize_newlines (str)
   local out = {}
   local n = 1;
   local search_start = 1
   local str_len = #str
   while true do
      local nl_start = str:find('[\r\n]', search_start)
      if nl_start then
         out[n] = str:sub(search_start, nl_start - 1)
         out[n + 1] = nl_style
         n = n + 2
         
         if str:byte(nl_start) == '\r' and nl_start < str_len and str:byte(nl_start + 1) == '\n' then
            search_start = nl_start + 2
         else
            search_start = nl_start + 1
         end
      else
         out[n] = str:sub(search_start)
         n = n + 1
         break
      end
   end
   return table.concat(out);
end

function indent_newlines (str)
   return normalize_newlines(str):gsub(nl_style, nl_style .. get_indent())
end

do -- write
   local out = nil
   local n = 1
   local in_comment = false

   local function init ()
      reset_indent()
      out = { }
      n = 1
      in_comment = false
      write_prefix()
   end

   function nl ()
      if out == nil then
         init()
      end
      out[n] = nl_style
      n = n + 1
      write_indent()
      if in_comment then
         write(comment_line_prefix)
      end
   end

   local function write_table (table, visited_set)
      out[n] = tostring(table)
      n = n + 1
      local mt = getmetatable(table)
      if not (mt and mt.__tostring) and visited_set[table] == nil then
         visited_set[table] = true
         out[n] = ': '
         n = n + 1
         indent()
         for k,v in pairs(table) do
            nl()
            local t = type(k)
            if t == 'string' then
               out[n] = k
               n = n + 1
            elseif t == 'table' then
               write_table(k, visited_set)
            else
               out[n] = tostring(k)
               n = n + 1
            end
            out[n] = ': '
            n = n + 1
            t = type(v)
            if t == 'string' then
               out[n] = v
               n = n + 1
            elseif t == 'table' then
               write_table(v, visited_set)
            else
               out[n] = tostring(v)
               n = n + 1
            end
         end
         unindent()
      end
   end

   local function write_value (val)
      if val ~= nil then
         local t = type(val)
         if t == 'function' then
            write(val())
         elseif t == 'string' then
            out[n] = val
            n = n + 1
         elseif t == 'table' then
            write_table(val, {})
         else
            out[n] = tostring(val)
            n = n + 1
         end
      end
   end

   function write (...)
      if out == nil then
         init()
      end
      for i = 1, select('#', ...) do
         write_value(select(i, ...))
      end
   end

   function writeln (...)
      if out == nil then
         init()
      end
      write(...)
      nl()
   end

   function write_lines (...)
      if out == nil then
         init()
      end
      for i = 1, select('#', ...) do
         write_value(select(i, ...))
         nl()
      end
   end

   function begin_comment ()
      if out == nil then
         init()
      end
      if false == in_comment then
         in_comment = true
         write(comment_begin)
      end
   end
   
   function end_comment ()
      if true == in_comment then
         in_comment = false
         write(comment_end)
      end
   end

   function _finish ()
      write_postfix()

      local str = table.concat(out)
      out = nil

      if type(postprocess) == 'function' then
         str = postprocess(str)
      end

      return str
   end
end

function quiet (p)
   if p == false then
      prefix = nil
      postfix = nil
   else
      prefix = ''
      postfix = ''
   end
end

function write_prefix ()
   if prefix ~= nil then
      write(prefix)
   else
      nl()
      begin_comment()
      write(' ################# !! GENERATED CODE -- DO NOT MODIFY !! ################# ')
      end_comment()
      nl()
   end
end

function write_postfix ()
   reset_indent()
   if postfix ~= nil then
      write(postfix)
   else
      nl()
      begin_comment()
      write(' ######################### END OF GENERATED CODE ######################### ')
      end_comment()
   end
end

do -- dependencies
   local deps = { }

   function get_depfile_target ()
      return fs.ancestor_relative_path(file_path, root_dir)
   end

   function write_depfile ()
      if not depfile_path or depfile_path == '' then
         return
      end

      local depfile = fs.get_file_contents(depfile_path)
      local depfile_exists = true
      if nil == depfile then
         depfile = ''
         depfile_exists = false
      end

      do
         local prefix = get_depfile_target() .. ':'
         local depfile_line = { prefix }
         for k, v in pairs(deps) do
            depfile_line[#depfile_line + 1] = ' '
            depfile_line[#depfile_line + 1] = k
         end
         depfile_line = table.concat(depfile_line)

         local found_existing
         depfile = depfile:gsub(blt.gsub_escape(prefix) .. '[^\r\n]+', function ()
            found_existing = true
            return depfile_line
         end, 1)

         if not found_existing then
            depfile = depfile .. depfile_line .. '\n'
         end
      end

      if not depfile_exists then
         fs.create_dirs(fs.parent_path(depfile_path))
      end
      fs.put_file_contents(depfile_path, depfile)
   end

   function dependency (path)
      if path and path ~= '' then
         deps[path] = true
      end
   end
end

function load_file (path, chunk_name)
   local contents = fs.get_file_contents(path)
   if contents == nil then
      error('Path \'' .. path .. '\' does not exist!')
   end
   if not chunk_name then
      chunk_name = '@' .. fs.path_filename(path)
   end
   dependency(fs.ancestor_relative_path(path, root_dir))
   local chunk, err = load(contents, chunk_name)
   if not chunk then error(err) end
   return chunk
end

function get_file_contents (path)
   local contents = fs.get_file_contents(path)
   if contents == nil then 
      error('Path \'' .. path .. '\' does not exist!')
   end
   dependency(fs.ancestor_relative_path(path, root_dir))
   return contents
end

function write_file (path)
   local contents = fs.get_file_contents(path)
   if contents ~= nil then
      dependency(fs.ancestor_relative_path(path, root_dir))
      write(indent_newlines(contents))
   end
end

-- Passes through the output from from a child process's stdout to the generated code.  stderr is not redirected.
function write_proc (command)
   local f = io.popen(command, 'r')
   write(indent_newlines(f:read('a')))
   f:close()
end

function template (source)
   local template_parts = {}

   local parse_text = function (text)
      local search_start = 1
      while true do
         local nl_start = text:find('[\r\n]', search_start)
         if nl_start then
            template_parts[#template_parts + 1] = text:sub(search_start, nl_start - 1)
            template_parts[#template_parts + 1] = nl
            
            if text:byte(nl_start) == '\r' and nl_start < #text and text:byte(nl_start + 1) == '\n' then
               search_start = nl_start + 2
            else
               search_start = nl_start + 1
            end
         else
            template_parts[#template_parts + 1] = text:sub(search_start)
            return
         end
      end
   end

   local env = {}

   local source_len = #source
   local search_start = 1
   while true do
      local interp_start = source:find('`', search_start, true)
      if not interp_start then break end

      if interp_start > search_start then
         parse_text(source:sub(search_start, interp_start - 1))
      end

      search_start = interp_start + 1

      local interp_end = source:find('`', search_start, true)
      if not interp_end then interp_end = source_len + 1 end

      if interp_end == search_start then
         -- empty interp means write a backtick
         template_parts[#template_parts + 1] = '`'
      else
         local interp = source:sub(search_start, interp_end - 1)
         local interp_name = interp
         if not interp:find('[\r\n]') then
            interp = 'return ' .. interp
         end

         local interp_fn, err = load(interp, interp_name, 't', env)
         if not interp_fn then error(err) end
         template_parts[#template_parts + 1] = interp_fn
      end

      search_start = interp_end + 1
   end

   if (search_start <= source_len) then
      parse_text(source:sub(search_start))
   end

   local env_mt = {}
   env_mt.__newindex = function (table, slot, value)
      env_mt.context[slot] = value
   end

   env_mt.__index = function (table, slot)
      if env_mt.context then
         local context_value = env_mt.context[slot]
         if context_value ~= nil then
            return context_value
         elseif slot == '_X' then
            return env_mt.context
         end
      end
      return _ENV[slot]
   end
   setmetatable(env, env_mt)

   return function (context, ...)
      env_mt.context = context
      for i,v in ipairs(template_parts) do
         if type(v) == 'function' then
            if (v == nl) then
               nl()
            else
               write(v(...))
            end
         else
            write(v)
         end
      end
   end
end

do -- include
   local chunks = { }
   local include_dirs = { }

   function get_include (include_name)
      if not include_name then
         error 'Must specify include script name!'
      end
      
      local existing = chunks[include_name]
      if existing ~= nil then
         return existing
      end

      local path = fs.resolve_path(include_name, include_dirs)
      if path and fs.stat(fs.canonical_path(path)).kind == 'file' then
         dependency(fs.ancestor_relative_path(path, root_dir))
         local contents = fs.get_file_contents(path)
         local fn, err = load(contents, '@' .. include_name)
         if not fn then error(err) end
         chunks[include_name] = fn
         return fn
      end

      path = fs.resolve_path(include_name .. '.lua', include_dirs)
      if path and fs.stat(fs.canonical_path(path)).kind == 'file' then
         dependency(fs.ancestor_relative_path(path, root_dir))
         local contents = fs.get_file_contents(path)
         local fn, err = load(contents, '@' .. include_name .. '.lua')
         if not fn then error(err) end
         chunks[include_name] = fn
         return fn
      end

      error('No include found matching \'' .. include_name .. '\'')
   end

   function register_include_dir (path)
      local n = #include_dirs
      for i = 1, n do
         if include_dirs[i] == path then
            return
         end
      end
      include_dirs[n + 1] = fs.absolute_path(path)
   end

   function resolve_include_path (path)
      return fs.resolve_path(path, include_dirs)
   end
end


function include (include_name, ...)
   return get_include(include_name)(...)
end

function import_limprc (path)
   local p = fs.compose_path(path, '.limprc')
   if fs.stat(p).kind == 'file' then
      limprc_path = p
      root_dir = path
      dofile(p)
      return true
   end

   local parent = fs.parent_path(path)

   if parent == "" then
      root_dir = path
      return false
   end

   return import_limprc(parent)
end

import_limprc(fs.parent_path(file_path))
