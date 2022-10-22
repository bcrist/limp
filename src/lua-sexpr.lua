local parser_meta = ...

parser_meta.require_open = function(parser)
    if not parser:open() then
        parser:print_parse_error_context()
        error("Expected '('")
    end
end

parser_meta.require_close = function(parser)
    if not parser:close() then
        parser:print_parse_error_context()
        error("Expected ')'")
    end
end

parser_meta.require_done = function(parser)
    if not parser:done() then
        parser:print_parse_error_context()
        error("Expected end of input")
    end
end

parser_meta.require_expression = function(parser, expected)
    if expected == nil then
        local result = parser:expression()
        if result == nil then
            parser:print_parse_error_context()
            error("Expected (expression")
        end
        return result
    elseif not parser:expression(expected) then
        parser:print_parse_error_context()
        error("Expected (" .. expected)
    end
end

parser_meta.require_string = function(parser, expected)
    if expected == nil then
        local result = parser:string()
        if result == nil then
            parser:print_parse_error_context()
            error("Expected string")
        end
        return result
    elseif not parser:string(expected) then
        parser:print_parse_error_context()
        error("Expected " .. expected)
    end
end

parser_meta.require_float = function(parser)
    local result = parser:float()
    if result == nil then
        parser:print_parse_error_context()
        error("Expected number")
    end
    return result
end

parser_meta.require_int = function(parser, radix)
    local result = parser:int(radix)
    if result == nil then
        parser:print_parse_error_context()
        error("Expected integer")
    end
    return result
end

parser_meta.require_unsigned = function(parser, radix)
    local result = parser:unsigned(radix)
    if result == nil then
        parser:print_parse_error_context()
        error("Expected unsigned integer")
    end
    return result
end

parser_meta.require_array_item = function(parser)
    local result = parser:array_item()
    if result == nil then
        parser:print_parse_error_context()
        error("Expected value")
    end
    return result
end

parser_meta.require_array = function(parser, expected)
    local result = parser:array(expected)
    if result == nil then
        parser:print_parse_error_context()
        if expected == nil then
            error("Expected array")
        else
            error("Expected array " .. expected)
        end
    end
    return result
end

parser_meta.require_property = function(parser, expected)
    local key, value = parser:property(expected)
    if key == nil then
        parser:print_parse_error_context()
        if expected == nil then
            error("Expected property")
        else
            error("Expected property " .. expected)
        end
    end
    return key, value
end

parser_meta.require_object = function(parser, expected)
    local result = parser:object(expected)
    if result == nil then
        parser:print_parse_error_context()
        if expected == nil then
            error("Expected object")
        else
            error("Expected object " .. expected)
        end
    end
    return result
end

parser_meta.array_item = function (parser)
    local val = parser:array()
    if val ~= nil then return val end
    
    val = parser:int()
    if val ~= nil then return val end

    val = parser:float()
    if val ~= nil then return val end

    return parser:string()
end

parser_meta.array_items = function (parser, array)
    if array == nil then array = {} end
    while true do
        local val = parser:array_item()
        if val == nil then
            break
        else
            array[#array + 1] = val
        end
    end
    return array
end

parser_meta.array = function (parser, expected_expr_name)
    if expected_expr_name == nil then
        if not parser:open() then return end
    else
        if not parser:expression(expected_expr_name) then return end
    end
    local array = parser:array_items()
    parser:close()
    return array
end

parser_meta.property = function (parser, expected_key_or_table, ...) --> key, value
    local key
    if expected_key_or_table == nil then
        key = parser:expression()
        if key == nil then return end
    elseif type(expected_key_or_table) == 'string' then
        if not parser:expression(expected_key_or_table) then return end
        key = expected_key_or_table
    else
        local visitor = expected_key_or_table
        key = parser:expression()
        if key == nil then return end
        local value = visitor[key]
        if value == nil then
            parser:print_parse_error_context()
            error("Visitor has no handler for property " .. key)
        elseif type(value) == 'function' then
            value = value(parser, key, ...)
        end
        return key, value
    end

    local value = nil
    while true do
        local k,v = parser:property()
        if v ~= nil then
            if value == nil then
                value = {}
            elseif type(value) == 'table' then
                value[k] = v
            else
                value = { value }
                value[k] = v
            end
        else
            local v = parser:array_item()
            if v == nil then
                if value == nil then
                    value = true
                end
                break
            elseif value == nil then
                value = v
            elseif type(value) == 'table' then
                value[#value + 1] = v
            else
                value = { value, v }
            end
        end
    end

    parser:close()

    return key, value
end

parser_meta.object_items = function (parser, obj)
    if obj == nil then obj = {} end
    while true do
        local key, val = parser:property()
        if key ~= nil then
            obj[key] = val
        else
            val = parser:array_item()
            if val == nil then
                break
            else
                obj[#obj + 1] = val
            end
        end
    end
    return obj
end

parser_meta.object = function (parser, expected_expr_name)
    if expected_expr_name == nil then
        if not parser:open() then return end
    else
        if not parser:expression(expected_expr_name) then return end
    end
    local obj = parser:object_items()
    parser:close()
    return obj
end
