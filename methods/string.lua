local methods = {}

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
        local success, length = pcall(buffer.len, value)
        if success and length then
            return "buffer(" .. length .. " bytes)"
        else
            return "buffer(?? bytes)"
        end
    else
        return tostring(value)
    end
end

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
        local success, length = pcall(buffer.len, data)
        if success and length then
            return "buffer.create(" .. length .. ")"
        else
            return "buffer.create(0) -- Invalid buffer"
        end
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

local function bufferToHex(bufferData)
    local hexString = ""
    local bufferLength = buffer.len(bufferData)
    
    for i = 0, bufferLength - 1 do
        hexString = hexString .. string.format("%02X ", buffer.readu8(bufferData, i))
    end
    
    return hexString:sub(1, -2) -- Remove trailing space
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
methods.cleanRemoteName = cleanRemoteName
return methods
