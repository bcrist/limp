    /*!!

local test = template [[
Hello `name`!
`values`
]]

list_item = template '<li>`it`</li>'
list = template [[<ul>`
indent()
for i,v in ipairs(table.pack(...)) do
    nl()
    list_item { it = v }
end
unindent()
`
</ul>
]]

test {
    name='World',
    values = function()
        list(nil, 'b')
        list(nil, 'b', 1, true, false)
    end
}

--write(_G)

    !! 15 */
    /* ################# !! GENERATED CODE -- DO NOT MODIFY !! ################# */
    Hello World!
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
    1
    2
    3
    4


/*!!
local src = [[
    (
        (apple)
        (banana 1 2 3 (asdf 1) 4 )
        1.0 -23 " a b c "
        (asdf fdsa)
    )
]]

local parser = sx.parser(src)
--write(parser:require_object())
--write(parser:require_array())
--parser = sx.parser(src)
parser:require_open()
    parser:require_expression("apple")
    parser:require_close()

    parser:require_expression("banana")
    parser:ignore_remaining_expression()

    if parser:require_float() ~= 1.0 then error("expected 1.0") end
    if parser:require_int() ~= -23 then error("expected -23") end
    if parser:require_string() ~= " a b c " then error("expected string") end
parser:ignore_remaining_expression()
parser:require_done()

!! 4 */
/* ################# !! GENERATED CODE -- DO NOT MODIFY !! ################# */

/* ######################### END OF GENERATED CODE ######################### */
