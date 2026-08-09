local methods = {}

local BUFFER_PREVIEW_BYTES = 64

local gsubCharacters = {
    ["\""] = "\\\"",
    ["\\"] = "\\\\",
    ["\0"] = "\\0",
    ["\n"] = "\\n",
    ["\t"] = "\\t",
    ["\f"] = "\\f",
    ["\r"] = "\\r",
    ["\v"] = "\\v",
    ["\a"] = "\\a",
    ["\b"] = "\\b"
}

local function getBufferContents(bufferData)
    local success, length = pcall(buffer.len, bufferData)
    if not success or type(length) ~= "number" then
        return nil, nil
    end

    local tostringSuccess, contents = pcall(buffer.tostring, bufferData)
    if tostringSuccess and type(contents) == "string" then
        return contents, length
    end

    local chunks = {}
    for i = 0, length - 1 do
        local byteSuccess, byteValue = pcall(buffer.readu8, bufferData, i)
        chunks[i + 1] = string.char((byteSuccess and byteValue) or 0)
    end

    return table.concat(chunks), length
end

local function isMostlyText(contents)
    local length = #contents
    if length == 0 then
        return true
    end

    local printable = 0
    for i = 1, length do
        local byteValue = contents:byte(i)
        if (byteValue >= 32 and byteValue <= 126) or byteValue == 9 or byteValue == 10 or byteValue == 13 then
            printable = printable + 1
        end
    end

    return (printable / length) >= 0.85
end

local function escapePreviewText(contents)
    return contents:gsub("[%c%z]", function(character)
        local byteValue = character:byte()
        if byteValue == 9 then
            return "\\t"
        elseif byteValue == 10 then
            return "\\n"
        elseif byteValue == 13 then
            return "\\r"
        end

        return string.format("\\x%02X", byteValue)
    end)
end

local function bytesToLuaString(contents)
    local chunks = { '"' }

    for i = 1, #contents do
        local byteValue = contents:byte(i)
        if byteValue == 34 then
            chunks[#chunks + 1] = '\\"'
        elseif byteValue == 92 then
            chunks[#chunks + 1] = '\\\\'
        elseif byteValue >= 32 and byteValue <= 126 then
            chunks[#chunks + 1] = string.char(byteValue)
        else
            chunks[#chunks + 1] = string.format("\\x%02X", byteValue)
        end
    end

    chunks[#chunks + 1] = '"'
    return table.concat(chunks)
end

local function bufferToHex(bufferData, maxBytes)
    local contents, length = getBufferContents(bufferData)
    if not contents then
        return ""
    end

    local limit = length
    if type(maxBytes) == "number" then
        limit = math.min(length, maxBytes)
    end

    local chunks = {}
    for i = 1, limit do
        chunks[i] = string.format("%02X", contents:byte(i))
    end

    local hexString = table.concat(chunks, " ")
    if limit < length then
        return hexString .. " ..."
    end

    return hexString
end

local function decodeBuffer(bufferData)
    local contents, length = getBufferContents(bufferData)
    if not contents then
        return "buffer(?? bytes)"
    end

    if length == 0 then
        return "buffer(0 bytes)"
    end

    if isMostlyText(contents) then
        local preview = contents
        if #preview > BUFFER_PREVIEW_BYTES then
            preview = preview:sub(1, BUFFER_PREVIEW_BYTES) .. "..."
        end

        return ("buffer(%d): %s"):format(length, escapePreviewText(preview))
    end

    return ("buffer(%d): %s"):format(length, bufferToHex(bufferData, BUFFER_PREVIEW_BYTES))
end

local function bufferToLua(bufferData)
    local contents, length = getBufferContents(bufferData)
    if not contents then
        return "buffer.create(0) -- Invalid buffer"
    end

    if length == 0 then
        return "buffer.create(0)"
    end

    if buffer.fromstring then
        return "buffer.fromstring(" .. bytesToLuaString(contents) .. ")"
    end

    local lines = {
        "(function()",
        ("\tlocal b = buffer.create(%d)"):format(length)
    }

    for i = 1, length do
        lines[#lines + 1] = ("\tbuffer.writeu8(b, %d, %d)"):format(i - 1, contents:byte(i))
    end

    lines[#lines + 1] = "\treturn b"
    lines[#lines + 1] = "end)()"
    return table.concat(lines, "\n")
end

local function toString(value)
    local dataType = typeof(value)

    if dataType == "userdata" or dataType == "table" then
        local mt = getMetatable(value)
        local __tostring = mt and rawget(mt, "__tostring")

        if not mt or (mt and not __tostring) then 
            return tostring(value) 
        end

        rawset(mt, "__tostring", nil)
        
        value = tostring(value):gsub((dataType == "userdata" and "userdata: ") or "table: ", '')
        
        rawset(mt, "__tostring", __tostring)

        return value 
    elseif type(value) == "userdata" then
        return userdataValue(value)
    elseif dataType == "function" then
        local closureName = getInfo(value).name or ''
        return (closureName == '' and "Unnamed function") or closureName
    elseif dataType == "buffer" then
        return decodeBuffer(value)
    else
        return tostring(value)
    end
end

local function dataToString(data)
    local dataType = type(data)
    local robloxDataType = typeof(data)

    if dataType == "string" then
        return '"' .. data:gsub("[%c%z\\\"]", gsubCharacters) .. '"'
    elseif dataType == "table" then
        return tableToString(data)
    elseif dataType == "userdata" then
        if typeof(data) == "Instance" then
            return getInstancePath(data)
        end

        return userdataValue(data)
    elseif robloxDataType == "buffer" then
        return bufferToLua(data)
    end

    return tostring(data)
end

local function toUnicode(string)
    local codepoints = "utf8.char("
    
    for _i, v in utf8.codes(string) do
        codepoints = codepoints .. v .. ', '
    end
    
    return codepoints:sub(1, -3) .. ')'
end

local function cleanRemoteName(name)
    -- Handle Unicode escape sequences and special characters in remote names
    local cleanName = name
    
    -- Replace common Unicode escape sequences with readable characters
    cleanName = cleanName:gsub("\\226\\128\\139", "") -- Zero Width Space
    cleanName = cleanName:gsub("\\226\\128\\140", "") -- Zero Width Non-Joiner
    cleanName = cleanName:gsub("\\226\\128\\141", "") -- Zero Width Joiner
    cleanName = cleanName:gsub("\\226\\128\\142", "") -- Left-to-Right Mark
    cleanName = cleanName:gsub("\\226\\128\\143", "") -- Right-to-Left Mark
    
    -- Remove other common invisible characters
    cleanName = cleanName:gsub("[\1-\31\127-\159]", "") -- Control characters
    cleanName = cleanName:gsub("[\194-\244][\128-\191]*", function(match)
        -- Handle UTF-8 sequences that might be invisible
        local bytes = {}
        for i = 1, #match do
            table.insert(bytes, match:byte(i))
        end
        
        -- Check for common invisible Unicode characters
        if #bytes == 3 and bytes[1] == 226 and bytes[2] == 128 then
            if bytes[3] >= 139 and bytes[3] <= 143 then
                return "" -- Remove invisible characters
            end
        end
        
        return match -- Keep visible characters
    end)
    
    -- If the name becomes empty or only whitespace, provide a fallback
    cleanName = cleanName:match("^%s*(.-)%s*$") -- Trim whitespace
    if cleanName == "" then
        cleanName = "[Unnamed Remote]"
    end
    
    return cleanName
end

methods.toString = toString
methods.dataToString = dataToString
methods.toUnicode = toUnicode
methods.bufferToHex = bufferToHex
methods.decodeBuffer = decodeBuffer
methods.bufferToLua = bufferToLua
methods.cleanRemoteName = cleanRemoteName
return methods
