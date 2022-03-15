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

## Built-in Functions and Variables

All functions from the (Lua Standard Libraries](https://www.lua.org/manual/5.4/manual.html#6) are available for use.

    function nl ()

Writes a newline character or characters and any indentation/comment characters as necessary.

    function write (...)

Converts each each parameter to a string and writes it to the output in sequence, with no separators.  Tables with no `__tostring` metamethod will be recursively dumped as key-value pairs.  Functions will be called with no parameters and any returned results will be recursively written.  Other non-string values will be converted using `tostring()`.

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

    function fs.absolute_path ()
    function fs.canonical_path ()
    function fs.compose_path ()
    function fs.compose_path_slash ()
    function fs.parent_path ()
    function fs.ancestor_relative_path ()
    function fs.resolve_path ()
    function fs.path_stem ()
    function fs.path_filename ()
    function fs.path_extension ()
    function fs.replace_extension ()
    function fs.cwd ()
    function fs.set_cwd ()
    function fs.stat ()
    function fs.get_file_contents ()
    function fs.put_file_contents ()

TODO

    function util.deflate ()
    function util.inflate ()

TODO

    function trim_trailing_ws (str)

Returns a copy of `str` with any spaces or tabs removed from the end of each line.

    function normalize_newlines (str)

Returns a copy of `str` with all newlines normalized to `nl_style`

    function postprocess (str)

Called with the string containing the new output data just before it's inserted back into the file.  By default it just calls `trim_trailing_ws(str)`, but it can be replaced with another function or removed if desired.

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

The path to the `.limprc` file that was executed.

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

The detected character(s) that should be used to indicate a new line; `\n`, `\r`, or `\r\n`.  The last newline before the start of the LIMP comment will be used, unless it begins on the first line of the file, in which case it will look at the first ~50 lines and pick whichever ending is most frequently used.  If there are no newlines at all, `\r\n` will be used on Windows, and `\n` on any other platform.

    backtick

A string containing a single backtick character.

    function get_depfile_target ()
    function write_depfile ()
    function dependency (path)
    function load_file (path, chunk_name)
    function get_file_contents (path)
    function register_include_dir (path)
    function include (include_name)
    function get_include (include_name)
    function resolve_include_path (path)
    function import_limprc (path)

TODO
