# LIMP

The Lua Inline Metaprogramming Preprocessor (LIMP) is a command line tool which looks for specially constructed comments in source code, executes them as Lua scripts, and inserts or replaces the results in the original source file.  It can be embedded in almost any host language (as long as it has comments).


## Example

    /*!! write 'Hello World!' !! 4 */
    /* ################# !! GENERATED CODE -- DO NOT MODIFY !! ################# */
    Hello World!
    /* ######################### END OF GENERATED CODE ######################### */


LIMP comments begin and end with the host language's comment tokens.  Immediately following the comment opener, `!!` indicates that the comment should be processed by LIMP.  The rest of the comment, (or up to the next `!!` token, whichever is first), is treated as a Lua program and executed.
That program can issue write commands to build up a chunk of output text, which will be inserted after the LIMP comment.  Any previously generated output will be replaced when this happens.  Between the ending `!!` and comment closing tokens, the number of generated lines will be recorded (in this case, 4), so that LIMP will know how many lines to replace next time it runs.  Note this does mean you need to be careful not to delete lines manually within the generated output, lest you accidentally lose lines that appear after the generated code.

Note: LIMP does not do any Lua syntax parsing when looking for the LIMP and/or comment end tokens.  In particular '!!' will be found even if it is inside a Lua string literal.


## Language Configuration

The sequences of characters that are treated as comment openers and closers can be customized by creating a `.limplangs` file in the directory that contains the limp executable.  Blank lines and lines that begin with `#` are ignored.  Otherwise, each line must have 3 or 4 tokens separated by whitespace.  The first is the file extension for which the line applies (without the leading `.`).  The second token denotes the start of a comment in that language, and the third token denotes the end of a comment.  If there is a fourth token, it should appear at the beginning of every line of a multi-line comment (this is useful for languages that only have single-line comments). If the same extension is specified multiple times, only the last one is valid.  If a line is specified for the extension `!!`, it overrides the default `!!` tokens that indicate the start and end of Lua code.

## Extensions and Project-specific Libraries

LIMP will set up a new Lua environment for each file that contains LIMP comments.  Before it executes any comments, it will look for a `.limprc` file in the same directory as the file to be processed, or a parent directory (it will stop at the closest one it finds).  If found, it will execute that file as a Lua chunk in the environment that it has created.  This means you can set up access to any additional libraries, include paths, etc. that you might want, without cluttering up individual LIMP comments or needing to repeat it in many places.

## Strict Mode

[Strict Mode](http://lua-users.org/wiki/DetectingUndefinedVariables) is enabled by default for LIMP programs.  You can disable it by setting `__STRICT = false` either in a LIMP comment or `.limprc`.

## Backtick Templates

The built-in `template` function can be used to make code generation tasks easier to read and less error prone compared to individual `write` calls.
It takes a single string parameter containing the template definition.  Backticks can be used to delimit text substitutions that should be made when evaluating the template.  This is a little bit like the string interpolation featured in some programming languages (although usually `${}` is used for those).  `template` returns a function which takes a context table.  The keys of that table are then available as global variables to the interpolated sections between backticks.  Each section is parsed as a separate chunk, using a metatable on the global table to delegate to either the context object or the parent global table.  If the interpolated section contains no newlines, it must be a `return`-able expression.  Returned values and non-interpolated sections are passed to `write`.  A double backtick acts as an escape sequence to insert a single backtick, or you can use the built-in `backtick` global variable.

### Template Examples

    /*!! 
    local simple = template [[`kind` is a fruit!`nl`]]
    simple {kind='Banana'}
    simple {kind='Apple'}
    simple {kind='Orange'}
    simple {kind='Kiwi'}
    !! 8 */
    /* ################# !! GENERATED CODE -- DO NOT MODIFY !! ################# */
    Banana is a fruit!
    Apple is a fruit!
    Orange is a fruit!
    Kiwi is a fruit!

    /* ######################### END OF GENERATED CODE ######################### */



    /*!! 
    local my_template = template [[Hello `name`!`nl, values`]]

    list_item = template '<li>`it`</li>'
    list = template [[<ul>`
        indent()
        for i,v in ipairs(table.pack(...)) do
            nl()
            list_item { it = v }
        end
        unindent()
        nl()
        `</ul>`
        nl()
        ]]

    my_template {
        name = 'Complicated World',
        values = function()
            list(nil, 'b')
            list(nil, 'b', 1, true, false)
        end
    }

    !! 14 */
    /* ################# !! GENERATED CODE -- DO NOT MODIFY !! ################# */
    Hello Complicated World!
    <ul>
       <li>b</li>
    </ul>
    <ul>
       <li>b</li>
       <li>1</li>
       <li>true</li>
       <li>false</li>
    </ul>

    /* ######################### END OF GENERATED CODE ######################### */

## S-Expression Parsing

An S-Expression parser is built into LIMP which provides an easy way to import human-readable data to be processed.
A parser can be constructed from an S-expression string, and provides a variety of methods to extract data from the
S-expression one piece at a time.  The simplest way to use it is something like this:

    local source = [[
        (1 2 3 (subarray 2 3 4.0))
    ]]
    local parser = sx.parser(source)
    local result = parser:array()

This will produce a table equivalent to this:

    result = { 1, 2, 3, { 'subarray', 2, 3, 4.0 }}

A common idiom with S-expressions is that the first value in a subexpression is treated as a property name of a key-value pair.
The `object()` method can be used to take advantage of this:

    parser = sx.parser(source)
    result = parser:object()

This will produce a table equivalent to this:

    result = { 1, 2, 3, subarray = { 2, 3, 4.0 }}

Note that there is a possibility of data loss here (e.g. if there were multiple `subarray` expressions within the same outer expression)
and Lua will not retain the relative ordering for expressions with multiple properties.

Sometimes you may want more structure and control over the parsing process, so there are a range of
lower-level methods to parse more incrementally.  For example:

    source = [[
        (box 2 5 4 (color blue))
    ]]
    parser = sx.parser(source)
    parser:require_expression('box')
    local width = parser:float() or 1
    local height = parser:float() or 1
    local depth = parser:float() or 1
    local color = 'white'
    if parser:expression('color') then
        color = parser:require_string()
        parser:close()
    end
    parser:close()
    parser:require_done()

### S-Expression Parser Methods

Methods that begin with `require_` operate the same as their unprefixed versions, except any time `nil` or `false` would
be returned, an error is generated instead.

    function open (parser) --> bool
    function require_open (parser)

Consumes the next token from the parser if it is `(`.

    function close (parser) --> bool
    function require_close (parser)

Consumes the next token from the parser if it is `)`.

    function done (parser) --> bool
    function require_done (parser)

Checks if the parser has reached the end of the input.

    function expression (parser) --> string | nil
    function expression (parser, expected) --> bool
    function require_expression (parser) --> string
    function require_expression (parser, expected)

Attempts to consume the next 2 tokens from the parser if they are `(` and a string.  If `expected` is provided, the second token must be that exact string in order for any tokens to be consumed.

    function string (parser) --> string | nil
    function string (parser, expected) --> bool
    function require_string (parser) --> string
    function require_string (parser, expected)

Attempts to consume the next token from the parser if it is a string/value.  If `expected` is provided, it must be that exact string in order to be consumed.

    function float (parser) --> number | nil
    function require_float (parser) --> float

Attempts to consume the next token from the parser if it can be parsed as a floating point number.

    function int (parser, radix = 10) --> integer | nil
    function require_int (parser, radix = 10) --> integer

Attempts to consume the next token from the parser if it can be parsed as a signed integer.

    function unsigned (parser, radix = 10) --> integer | nil
    function require_unsigned (parser, radix = 10) --> integer

Attempts to consume the next token from the parser if it can be parsed as an unsigned integer.

    function array_item (parser) --> * | nil
    function require_array_item (parser) --> *

Attempts to parse a number, string, or array.

    function array_items (parser, array = {}) --> table

Attempts to parse as many numbers, strings, or arrays as possible, and appends them to the provided table.

    function array (parser) --> table | nil
    function array (parser, expected) --> table | nil
    function require_array (parser) --> table
    function require_array (parser, expected) --> table

Attempts to consume a subexpression.  If `expected` is provided, the subexpression will only be consumed if it begins with this string,
as if using `if expression(expected) then ... end`.  Additional values/subexpressions will be parsed using `array_items`.

    function property (parser) --> key | nil, value | nil
    function property (parser, expected_key) --> key | nil, value | nil
    function require_property (parser) --> key, value
    function require_property (parser, expected_key) --> key, value

Attempts to consume a subexpression.  The first value in the subexpression is the key.  If there are no additional values, the value
is assumed to be `true`.  If there are more than one additional value, or if the value is a property itself, they are parsed as if by
`object_items`.  If `expected_key` is provided, the subexpression will only be consumed if the key matches that string.

    function property (parser, table, ...) --> key | nil, value | nil
    function require_property (parser, table, ...) --> key, value

Attempts to consume a subexpression.  The first value in the subexpression is the key.  A function will be looked up in the provided table.  That
function will be called and passed the parser, key name, and any additional parameters passed into `property`, and it should parse the remainder
of the subexpression and return a value.  A metatable can be used to handle/ignore unrecognized keys, otherwise such edge cases will result in an error.

    function object_items (parser, obj = {}) --> table

Attempts to parse as many properties, numbers, strings, or arrays as possible, inserting or appending them in the provided table.

    function object (parser) --> table | nil
    function object (parser, expected) --> table | nil
    function require_object (parser) --> table
    function require_object (parser, expected) --> table

Attempts to consume a subexpression.  If `expected` is provided, the subexpression will only be consumed if it begins with this string, as if using
`if expression(expected) then ... end`.  Additional values/subexpressions will be parsed using `object_items`.

    function ignore_remaining_expression (parser)

Ignore any remaining values or subexpressions and consume the `)` token that ends this expression.

    function print_parse_error_context (parser)

Print (to stderr) the line number and contents of the current line being parsed, and highlight the next unconsumed token.


## Built-in Functions and Variables

All functions from the [Lua Standard Libraries](https://www.lua.org/manual/5.4/manual.html#6) are available for use.

    function spairs (table)
    function spairs (table, comparator)

Iterator generator like `pairs`, except keys are visited in sorted order.  By default, the order is lexicographic, but a custom
comparator may be provided as for `table.sort`.

    function nl ()

Writes a newline character or characters and any indentation/comment characters as necessary.

    function write (...)

Converts each each parameter to a string and writes it to the output in sequence, with no separators.  Tables with no `__tostring` metamethod will be
recursively dumped as key-value pairs.  Functions will be called with no parameters and any returned results will be recursively written.  Other
non-string values will be converted using `tostring()`.

    function writeln (...)

Equivalent to `write(...) nl()`.

    function write_lines (...)

Same as `write (...)` except `nl()` will be called after each parameter is written.

    function write_file (path)

Loads the contents of the specified path, marking it as a dependency, writing it with normalized newlines and the current indentation level.

    function write_proc (cmd)

Executes the provided shell command via `io.popen`, writing the output with normalized newlines and the current indentation level.

    function template (source)

Defines a new backtick template function (see above for details).

    function begin_comment ()
    function end_comment ()

Writes `comment_begin`/`comment_end` as necessary and causes any `nl()` within the comment to output `comment_line_prefix` after any indentation.

    function indent (count = 1)
    function unindent (count = 1)
    function set_indent (count)
    function reset_indent ()

Changes the indentation level for any subsequent lines written.

    function get_indent ()

Returns a string composed of `base_indent` and `indent_char` repeated as necessary to achieve the current indent level.

    function write_indent ()

Equivalent to `write(get_indent())`.  Normally you don't need to call this directly, as `nl()` will call it automatically.

    function indent_newlines (str)

Returns a copy of `str` with newlines normalized, and each new line having `get_indent()` prepended.

    function sx.parser (str)

Returns a new parser to process the provided S-expression string.  See above for discussion of the methods available on this type of userdata object.

    function fs.absolute_path (path)

If `path` is already an absolute path, it is returned unchanged, otherwise an absolute path is constructed as if by calling `fs.compose_path(fs.cwd(), path)`.
This function does not access the filesystem.

    function fs.canonical_path (path)

Converts `path` to an absolute path (if necessary) and resolves any `..`, `.`, or symlink segments.  An error is thrown if the path does not exist or can't be accessed.

    function fs.compose_path (...)

Joins each of the provided path parts into a single path, using a directory separator appropriate for the current platform (including converting any directory
separators inside the path strings).  Only the first parameter may be an absolute path (but isn't required to be).  This function does not access the filesystem.

    function fs.compose_path_slash (...)

Same as `fs.compose_path(...)` but always uses `/` as a separator, even on Windows.

    function fs.parent_path (path)

Removes the filename or final directory name from a path.  If the path is a root path, an empty string is returned.  This function does not access the filesystem.

    function fs.ancestor_relative_path (child, ancestor)

Returns a path to `child` relative to the `ancestor` path, if the `child` path's starting segments are identical to `ancestor`.  Otherwise, returns `child`
unchanged.  If both paths are the same, `.` is returned.  If one path contains `..`, symlinks, etc. that do not appear in the other path, yet they are actually
equivalent, this function will not be able to generate a relative path.  This function does not access the filesystem.

    function fs.resolve_path (path, search, include_cwd = false)

Looks for an existing path in one or more directories and returns the first one it finds.  If `search` is a path, that directory is searched.  If `search` is
a table, each value contained in it is searched.  Use integer keys to ensure a consistent search order.  Finally if no match has been found yet and `include_cwd`
is true, the current directory is searched.

    function fs.path_stem (path)

Extracts the base filename from `path`, removing any file extension, parent directories, or path separators.  This function does not access the filesystem.

    function fs.path_filename (path)

Extracts the base filename from `path`, removeing parent directories or path separators.  This function does not access the filesystem.

    function fs.path_extension (path)

Extracts the file extension from `path`, including the preceeding `.`, or the empty string if the filename has no `.` characters.  This function does not access the filesystem.

    function fs.replace_extension (path, new_ext)

Removes the current extension (if any) from `path` and then adds on `new_ext`.  This function does not access the filesystem.

    function fs.cwd ()

Returns the current working directory (generally the path containing the file being processed, unless `set_cwd()` has been used).

    function fs.set_cwd (path)

Sets the current working directory to a new path.  Note this will be reset each time a new file is processed.

    function fs.stat (path)

Returns an object containing size, timestamps, type, kind, and mode/permissions for a file or directory.  If the file/directory does not exist, the kind will be
an empty string, and all other properties will be 0.

    function fs.get_file_contents (path)

Fully reads the contents of a file into a string.

    function fs.put_file_contents (path, data)

Writes a string to a file.  If the file already exists, it will be replaced.

    function fs.move (src, dest, force = false)

Renames a file or directory.  If `dest` already exists it will only be overwritten if it is the same kind as `src` (i.e. both files or directories) and `force` is true.

    function fs.copy (src, dest, force = false)

Copies a file or directory.  If `dest` already exists it will only be overwritten if it is the same kind as `src` (i.e. both files or directories) and `force` is true.
When "overwriting" a directory, files in the old directory will only be replaced if they also exist in the source directory.

    function fs.delete (path, recursive = false)

Deletes a file or directory.  If `recursive` is true, a directory can be deleted even if it is not empty.

    function fs.ensure_dir_exists (path)

Creates any directories necessary to ensure that `path` exists and is a directory.  Throws an error if not possible due to a file existing with a conflicting name.

    function util.deflate (uncompressed, level = 8, encode_length = false)

Returns a zlib-compressed version of the `uncompressed` string.  If `encode_length` is true, an extra 8 bytes are prepended indicating the original uncompressed
length of `data`, which is needed for `util.inflate()`.

    function util.inflate (compressed, uncompressed_length = nil)

Decompresses zlib-compressed data.  If `uncompressed_length` is not provided, the compressed data must have been generated by `util.deflate(?, ?, true)`.

    function trim_trailing_ws (str)

Returns a copy of `str` with any spaces or tabs removed from the end of each line.

    function normalize_newlines (str)

Returns a copy of `str` with all newlines normalized to `nl_style`

    function postprocess (str)

Called with the string containing the new output data just before it's inserted back into the file.  By default it just calls `trim_trailing_ws(str)`, but it
can be replaced with another function or removed if desired.

    function write_prefix ()

Called just before the first output is generated for each LIMP.  It can be replaced to hook in custom logic.

    function write_postfix ()

Called at the end of each LIMP just before `postprocess` is called.  It can be replaced to hook in custom logic.

    prefix
    postfix

If set, these will be written automatically by `write_prefix`/`write_postfix` instead of the default `GENERATED CODE -- DO NOT MODIFY` warning.

    function quiet ()

Sets `prefix` and `postfix` to the empty string, disabling the generated code warning.

    file_path

The path to the file containing the LIMP being processed.

    limprc_path

The path to the `.limprc` file that was executed.  If multiple `.limprc` files have been run (due to `import_limprc` being called again), only the most
recent path is reflected here.

    comment_begin
    comment_end
    comment_line_prefix

Strings corresponding to the detected comment tokens used in this file (e.g. from `.limplangs`).

    last_generated_data

A string containing the data from the file that will be replaced by the output currently being generated.

    base_indent

Any characters at the start of the line containing the start of the LIMP comment are placed here.  It will automatically be inserted after a call to `nl()`.

    indent_size
    indent_char

Configures the characters to use for automatic indentation.

    nl_style

The detected character(s) that should be used to indicate a new line; `\n`, `\r`, or `\r\n`.  The last newline before the start of the LIMP comment
will be used, unless it begins on the first line of the file, in which case it will look at the first ~50 lines and pick whichever ending is most
frequently used.  If there are no newlines at all, `\r\n` will be used on Windows, and `\n` on any other platform.

    backtick

A string containing a single backtick character.

    function dependency (path)
    function get_depfile_target ()
    function write_depfile ()

Not yet implemented.

    function load_file (path, chunk_name)

Similar to the Lua built-in `loadfile(path)` but the loaded file is marked as a dependency of the currently processing file.

    function get_file_contents (path)

Identical to `fs.get_file_contents (path)` but the file is marked as a dependency of the currently processing file.

    function include (include_name)

Searches all currently registered include paths and the current directory for a `.lua` file with the specified name and executes it.  The name
provided does not need to include the `.lua` extension.

    function register_include_dir (path)

Adds a new path to search for `.lua` files when attempting to resolve `include(...)` calls.  Normally this would be used in a `.limprc` file to set up 

    function get_include (include_name)

Same as `include(...)` except instead of running the included chunk, it is returned as a function.

    function resolve_include_path (path)

Searches for the provided path among all current include paths, using `fs.resolve_path()`.  This can be useful to find other types of files
that live "next to" an included Lua script.

    function import_limprc (path)

Searches for a `.limprc` file in the provided path, or a parent of that path, and executes it.  This will be called automatically when processing
a new file, but you can chain `.limprc` files together by putting `import_limprc(fs.parent_path(limprc_path))` inside a `.limprc` file in a
subdirectory of the project's root.
