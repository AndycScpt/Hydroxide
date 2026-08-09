local methods = {}

local BUFFER_PREVIEW_BYTES = 64
local BUFFER_ANALYSIS_MAX = 256

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

local function isPrintableByte(byteValue)
    return (byteValue >= 32 and byteValue <= 126) or byteValue == 9 or byteValue == 10 or byteValue == 13
end

local function isMostlyText(contents)
    local length = #contents
    if length == 0 then
        return true
    end

    local printable = 0
    for i = 1, length do
        if isPrintableByte(contents:byte(i)) then
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

local function asciiGlyph(byteValue)
    if byteValue >= 32 and byteValue <= 126 then
        return string.char(byteValue)
    end

    return "."
end

local function tryRead(bufferData, reader, offset)
    local ok, value = pcall(reader, bufferData, offset)
    if ok then
        return value
    end
end

local function formatNumber(value)
    if type(value) ~= "number" then
        return tostring(value)
    end

    if value ~= value then
        return "nan"
    end

    if value == math.huge then
        return "inf"
    end

    if value == -math.huge then
        return "-inf"
    end

    if value % 1 == 0 and math.abs(value) <= 2147483647 then
        return tostring(value)
    end

    return string.format("%.6g", value)
end

local function formatHexDump(contents, maxBytes)
    local length = #contents
    local limit = length
    if type(maxBytes) == "number" then
        limit = math.min(length, maxBytes)
    end

    local lines = {}
    for offset = 0, limit - 1, 16 do
        local hexParts = {}
        local asciiParts = {}

        for i = 0, 15 do
            local index = offset + i
            if index < limit then
                local byteValue = contents:byte(index + 1)
                hexParts[#hexParts + 1] = string.format("%02X", byteValue)
                asciiParts[#asciiParts + 1] = asciiGlyph(byteValue)
            else
                hexParts[#hexParts + 1] = "  "
                asciiParts[#asciiParts + 1] = " "
            end

            if i == 7 then
                hexParts[#hexParts + 1] = ""
            end
        end

        lines[#lines + 1] = string.format(
            "  %04X  %-48s |%s|",
            offset,
            table.concat(hexParts, " "),
            table.concat(asciiParts)
        )
    end

    if limit < length then
        lines[#lines + 1] = string.format("  ... (%d more bytes)", length - limit)
    end

    return table.concat(lines, "\n")
end

local function findAsciiRuns(contents, maxRuns)
    local runs = {}
    local length = #contents
    local i = 1

    while i <= length and #runs < (maxRuns or 8) do
        local byteValue = contents:byte(i)
        if byteValue >= 32 and byteValue <= 126 then
            local start = i
            while i <= length do
                local nextByte = contents:byte(i)
                if not (nextByte >= 32 and nextByte <= 126) then
                    break
                end
                i = i + 1
            end

            local text = contents:sub(start, i - 1)
            if #text >= 2 then
                runs[#runs + 1] = {
                    offset = start - 1,
                    text = text
                }
            end
        else
            i = i + 1
        end
    end

    return runs
end

local function guessFields(bufferData, contents)
    local length = #contents
    local fields = {}
    local offset = 0

    local function push(field)
        fields[#fields + 1] = field
    end

    while offset < length and #fields < 32 do
        local remaining = length - offset

        -- Zero run
        if contents:byte(offset + 1) == 0 then
            local zeroEnd = offset
            while zeroEnd < length and contents:byte(zeroEnd + 1) == 0 do
                zeroEnd = zeroEnd + 1
            end

            local zeroCount = zeroEnd - offset
            if zeroCount >= 2 then
                push({
                    offset = offset,
                    size = zeroCount,
                    kind = "padding",
                    summary = string.format("zero padding (%d bytes)", zeroCount)
                })
                offset = zeroEnd
            else
                push({
                    offset = offset,
                    size = 1,
                    kind = "u8",
                    summary = "u8 = 0"
                })
                offset = offset + 1
            end
        elseif remaining >= 8 and offset % 4 == 0 then
            local f64 = tryRead(bufferData, buffer.readf64, offset)
            local u32 = tryRead(bufferData, buffer.readu32, offset)
            local u32b = tryRead(bufferData, buffer.readu32, offset + 4)
            local looksFloat = type(f64) == "number"
                and f64 == f64
                and f64 ~= math.huge
                and f64 ~= -math.huge
                and math.abs(f64) > 1e-6
                and math.abs(f64) < 1e12

            -- Prefer 8-byte float when both u32 halves aren't tiny integers.
            if looksFloat and not (u32 and u32 < 100000 and u32b == 0) then
                push({
                    offset = offset,
                    size = 8,
                    kind = "f64",
                    summary = "f64 = " .. formatNumber(f64)
                })
                offset = offset + 8
            elseif remaining >= 4 then
                local f32 = tryRead(bufferData, buffer.readf32, offset)
                local i32 = tryRead(bufferData, buffer.readi32, offset)
                local looksF32 = type(f32) == "number"
                    and f32 == f32
                    and f32 ~= math.huge
                    and f32 ~= -math.huge
                    and math.abs(f32) > 1e-3
                    and math.abs(f32) < 1e9
                    and u32
                    and u32 > 65535

                if looksF32 then
                    push({
                        offset = offset,
                        size = 4,
                        kind = "f32",
                        summary = "f32 = " .. formatNumber(f32)
                    })
                else
                    local summary = "u32 = " .. formatNumber(u32) .. " / i32 = " .. formatNumber(i32)
                    if u32 and u32 <= 0xFFFF then
                        local u16 = tryRead(bufferData, buffer.readu16, offset)
                        summary = "u16 = " .. formatNumber(u16) .. " | " .. summary
                    end
                    push({
                        offset = offset,
                        size = 4,
                        kind = "u32",
                        summary = summary
                    })
                end
                offset = offset + 4
            end
        elseif remaining >= 4 then
            local u16 = tryRead(bufferData, buffer.readu16, offset)
            local nextByte = contents:byte(offset + 3)
            -- Prefer a narrow u16 when the next byte looks like a separate opcode/flag.
            if u16 and u16 < 4096 and nextByte and nextByte >= 0x80 then
                local i16 = tryRead(bufferData, buffer.readi16, offset)
                push({
                    offset = offset,
                    size = 2,
                    kind = "u16",
                    summary = "u16 = " .. formatNumber(u16) .. " / i16 = " .. formatNumber(i16)
                })
                offset = offset + 2
            else
                local u32 = tryRead(bufferData, buffer.readu32, offset)
                local i32 = tryRead(bufferData, buffer.readi32, offset)
                local f32 = tryRead(bufferData, buffer.readf32, offset)
                local summary = "u32 = " .. formatNumber(u32) .. " / i32 = " .. formatNumber(i32)

                if type(f32) == "number" and f32 == f32 and math.abs(f32) > 1e-3 and math.abs(f32) < 1e9 and u32 and u32 > 65535 then
                    summary = summary .. " / f32 = " .. formatNumber(f32)
                end

                push({
                    offset = offset,
                    size = 4,
                    kind = "u32",
                    summary = summary
                })
                offset = offset + 4
            end
        elseif remaining >= 2 then
            local u16 = tryRead(bufferData, buffer.readu16, offset)
            local i16 = tryRead(bufferData, buffer.readi16, offset)
            push({
                offset = offset,
                size = 2,
                kind = "u16",
                summary = "u16 = " .. formatNumber(u16) .. " / i16 = " .. formatNumber(i16)
            })
            offset = offset + 2
        else
            local u8 = contents:byte(offset + 1)
            local summary = string.format("u8 = %d (0x%02X)", u8, u8)
            if u8 >= 32 and u8 <= 126 then
                summary = summary .. string.format(" '%s'", string.char(u8))
            end
            push({
                offset = offset,
                size = 1,
                kind = "u8",
                summary = summary
            })
            offset = offset + 1
        end
    end

    return fields
end

local function buildWriteReconstruction(bufferData, contents)
    local length = #contents
    local lines = {
        "(function()",
        ("\tlocal b = buffer.create(%d)"):format(length)
    }

    local offset = 0
    while offset < length do
        local remaining = length - offset

        if contents:byte(offset + 1) == 0 then
            local zeroEnd = offset
            while zeroEnd < length and contents:byte(zeroEnd + 1) == 0 do
                zeroEnd = zeroEnd + 1
            end
            -- zeros are already the default from buffer.create
            offset = zeroEnd
        elseif remaining >= 4 then
            local u16 = tryRead(bufferData, buffer.readu16, offset)
            local nextByte = contents:byte(offset + 3)
            if u16 and u16 < 4096 and nextByte and nextByte >= 0x80 then
                lines[#lines + 1] = ("\tbuffer.writeu16(b, %d, %s)"):format(offset, formatNumber(u16))
                offset = offset + 2
            elseif offset % 4 == 0 then
                local u32 = tryRead(bufferData, buffer.readu32, offset)
                local f32 = tryRead(bufferData, buffer.readf32, offset)
                local looksF32 = type(f32) == "number"
                    and f32 == f32
                    and math.abs(f32) > 1e-3
                    and math.abs(f32) < 1e9
                    and u32
                    and u32 > 65535

                if looksF32 then
                    lines[#lines + 1] = ("\tbuffer.writef32(b, %d, %s)"):format(offset, formatNumber(f32))
                else
                    lines[#lines + 1] = ("\tbuffer.writeu32(b, %d, %s)"):format(offset, formatNumber(u32))
                end
                offset = offset + 4
            elseif remaining >= 2 and offset % 2 == 0 then
                lines[#lines + 1] = ("\tbuffer.writeu16(b, %d, %s)"):format(offset, formatNumber(u16))
                offset = offset + 2
            else
                local u8 = contents:byte(offset + 1)
                lines[#lines + 1] = ("\tbuffer.writeu8(b, %d, 0x%02X)"):format(offset, u8)
                offset = offset + 1
            end
        elseif remaining >= 2 and offset % 2 == 0 then
            local u16 = tryRead(bufferData, buffer.readu16, offset)
            lines[#lines + 1] = ("\tbuffer.writeu16(b, %d, %s)"):format(offset, formatNumber(u16))
            offset = offset + 2
        else
            local u8 = contents:byte(offset + 1)
            if u8 >= 32 and u8 <= 126 then
                lines[#lines + 1] = ("\tbuffer.writeu8(b, %d, 0x%02X) -- '%s'"):format(offset, u8, string.char(u8))
            else
                lines[#lines + 1] = ("\tbuffer.writeu8(b, %d, 0x%02X)"):format(offset, u8)
            end
            offset = offset + 1
        end
    end

    lines[#lines + 1] = "\treturn b"
    lines[#lines + 1] = "end)()"
    return table.concat(lines, "\n")
end

local function analyzeBuffer(bufferData)
    local contents, length = getBufferContents(bufferData)
    if not contents then
        return nil
    end

    local analysisLimit = math.min(length, BUFFER_ANALYSIS_MAX)
    local sliced = contents
    if analysisLimit < length then
        -- Keep full contents for reconstruction; dump/fields use limit via formatters.
    end

    local fields = guessFields(bufferData, contents:sub(1, analysisLimit))
    local asciiRuns = findAsciiRuns(contents:sub(1, analysisLimit), 8)

    return {
        contents = contents,
        length = length,
        hexDump = formatHexDump(contents, analysisLimit),
        fields = fields,
        asciiRuns = asciiRuns,
        mostlyText = isMostlyText(contents)
    }
end

local function formatBufferAnalysis(bufferData, label)
    local analysis = analyzeBuffer(bufferData)
    if not analysis then
        return "-- Invalid buffer"
    end

    local lines = {
        "--[[" .. (label and (" " .. label) or ""),
        ("Size: %d bytes"):format(analysis.length),
        "Hex:",
        analysis.hexDump
    }

    if #analysis.fields > 0 then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "Interpreted (little-endian guesses):"
        for _, field in ipairs(analysis.fields) do
            lines[#lines + 1] = string.format("  +0x%02X  %s", field.offset, field.summary)
        end
    end

    if #analysis.asciiRuns > 0 then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "ASCII runs:"
        for _, run in ipairs(analysis.asciiRuns) do
            lines[#lines + 1] = string.format("  +0x%02X  %s", run.offset, bytesToLuaString(run.text))
        end
    elseif analysis.mostlyText then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "Text: " .. bytesToLuaString(analysis.contents)
    end

    lines[#lines + 1] = ""
    lines[#lines + 1] = "Readable reconstruction:"
    for line in buildWriteReconstruction(bufferData, analysis.contents):gmatch("[^\n]+") do
        lines[#lines + 1] = "  " .. line
    end

    lines[#lines + 1] = "]]"
    return table.concat(lines, "\n")
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
    local analysis = analyzeBuffer(bufferData)
    if not analysis then
        return "buffer(?? bytes)"
    end

    if analysis.length == 0 then
        return "buffer(0 bytes)"
    end

    if analysis.mostlyText then
        local preview = analysis.contents
        if #preview > BUFFER_PREVIEW_BYTES then
            preview = preview:sub(1, BUFFER_PREVIEW_BYTES) .. "..."
        end

        return ("buffer(%d): %s"):format(analysis.length, escapePreviewText(preview))
    end

    local fieldPreview = {}
    for i = 1, math.min(3, #analysis.fields) do
        local field = analysis.fields[i]
        fieldPreview[#fieldPreview + 1] = string.format("+%02X %s", field.offset, field.summary)
    end

    if #fieldPreview > 0 then
        return ("buffer(%d): %s"):format(analysis.length, table.concat(fieldPreview, "; "))
    end

    return ("buffer(%d): %s"):format(analysis.length, bufferToHex(bufferData, BUFFER_PREVIEW_BYTES))
end

local function bufferToLua(bufferData, label)
    local contents, length = getBufferContents(bufferData)
    if not contents then
        return "buffer.create(0) -- Invalid buffer"
    end

    if length == 0 then
        return "buffer.create(0)"
    end

    local analysisComment = formatBufferAnalysis(bufferData, label)
    local valueExpr

    if buffer.fromstring then
        valueExpr = "buffer.fromstring(" .. bytesToLuaString(contents) .. ")"
    else
        valueExpr = buildWriteReconstruction(bufferData, contents)
    end

    return analysisComment .. "\n" .. valueExpr
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
methods.analyzeBuffer = analyzeBuffer
methods.formatBufferAnalysis = formatBufferAnalysis
methods.cleanRemoteName = cleanRemoteName
return methods
