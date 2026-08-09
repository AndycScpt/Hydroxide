local environment = assert(getgenv, "<OH> ~ Your exploit is not supported")()

if oh then
    oh.Exit()
end

local web = true
local user = "AndycScpt" -- change if you're using a fork
local branch = "revision"
local importCache = {}

local function hasMethods(methods)
    for name in pairs(methods) do
        if not environment[name] then
            return false
        end
    end

    return true
end

local function useMethods(module)
    for name, method in pairs(module) do
        if method then
            environment[name] = method
        end
    end
end

if Window and PROTOSMASHER_LOADED then
    getgenv().get_script_function = nil
end

local globalMethods = {
    checkCaller = checkcaller,
    newCClosure = newcclosure,
    hookFunction = hookfunction or detour_function,
    getGc = getgc or get_gc_objects,
    getInfo = debug.getinfo or getinfo,
    getSenv = getsenv,
    getMenv = getmenv or getsenv,
    getContext = getthreadcontext or get_thread_context or (syn and syn.get_thread_identity),
    getConnections = get_signal_cons or getconnections,
    getScriptClosure = getscriptclosure or get_script_function,
    getNamecallMethod = getnamecallmethod or get_namecall_method,
    getCallingScript = getcallingscript or get_calling_script,
    getLoadedModules = getloadedmodules or get_loaded_modules,
    getConstants = debug.getconstants or getconstants or getconsts,
    getUpvalues = debug.getupvalues or getupvalues or getupvals,
    getProtos = debug.getprotos or getprotos,
    getStack = debug.getstack or getstack,
    getConstant = debug.getconstant or getconstant or getconst,
    getUpvalue = debug.getupvalue or getupvalue or getupval,
    getProto = debug.getproto or getproto,
    getMetatable = getrawmetatable or debug.getmetatable,
    getHui = get_hidden_gui or gethui,
    setClipboard = setclipboard or writeclipboard,
    setConstant = debug.setconstant or setconstant or setconst,
    setContext = setthreadcontext or set_thread_context or (syn and syn.set_thread_identity),
    setUpvalue = debug.setupvalue or setupvalue or setupval,
    setStack = debug.setstack or setstack,
    setReadOnly = setreadonly or (make_writeable and function(table, readonly) if readonly then make_readonly(table) else make_writeable(table) end end),
    isLClosure = islclosure or is_l_closure or (iscclosure and function(closure) return not iscclosure(closure) end),
    isReadOnly = isreadonly or is_readonly,
    isXClosure = is_synapse_function or issentinelclosure or is_protosmasher_closure or is_sirhurt_closure or iselectronfunction or istempleclosure or checkclosure,
    hookMetaMethod = hookmetamethod or (hookfunction and function(object, method, hook) return hookfunction(getMetatable(object)[method], hook) end),
    readFile = readfile,
    writeFile = writefile,
    makeFolder = makefolder,
    isFolder = isfolder,
    isFile = isfile,
}

if PROTOSMASHER_LOADED then
    globalMethods.getConstant = function(closure, index)
        return globalMethods.getConstants(closure)[index]
    end
end

local oldGetUpvalue = globalMethods.getUpvalue
local oldGetUpvalues = globalMethods.getUpvalues

globalMethods.getUpvalue = function(closure, index)
    if type(closure) == "table" then
        return oldGetUpvalue(closure.Data, index)
    end

    return oldGetUpvalue(closure, index)
end

globalMethods.getUpvalues = function(closure)
    if type(closure) == "table" then
        return oldGetUpvalues(closure.Data)
    end

    return oldGetUpvalues(closure)
end

environment.hasMethods = hasMethods
environment.oh = {
    Events = {},
    Hooks = {},
    Cache = importCache,
    Methods = globalMethods,
    Constants = {
        Types = {
            ["nil"] = "rbxassetid://4800232219",
            table = "rbxassetid://4666594276",
            string = "rbxassetid://4666593882",
            number = "rbxassetid://4666593882",
            boolean = "rbxassetid://4666593882",
            userdata = "rbxassetid://4666594723",
            vector = "rbxassetid://4666594723",
            ["function"] = "rbxassetid://4666593447",
            ["thread"] = "rbxassetid://4666593447",
            ["integral"] = "rbxassetid://4666593882",
            buffer = "rbxassetid://4666593882"
        },
        Syntax = {
            ["nil"] = Color3.fromRGB(244, 135, 113),
            table = Color3.fromRGB(225, 225, 225),
            string = Color3.fromRGB(225, 150, 85),
            number = Color3.fromRGB(170, 225, 127),
            boolean = Color3.fromRGB(127, 200, 255),
            userdata = Color3.fromRGB(225, 225, 225),
            vector = Color3.fromRGB(225, 225, 225),
            ["function"] = Color3.fromRGB(225, 225, 225),
            ["thread"] = Color3.fromRGB(225, 225, 225),
            ["unnamed_function"] = Color3.fromRGB(175, 175, 175),
            buffer = Color3.fromRGB(255, 200, 100)
        }
    },
    Exit = function()
        for _i, event in pairs(oh.Events) do
            event:Disconnect()
        end

        for original, hook in pairs(oh.Hooks) do
            local hookType = type(hook)
            if hookType == "function" then
                hookFunction(hook, original)
            elseif hookType == "table" then
                hookFunction(hook.Closure.Data, hook.Original)
            end
        end

        local ui = importCache["rbxassetid://11389137937"]
        local assets = importCache["rbxassetid://5042114982"]

        if ui then
            unpack(ui):Destroy()
        end

        if assets then
            unpack(assets):Destroy()
        end
    end
}

if getConnections then 
    for __, connection in pairs(getConnections(game:GetService("ScriptContext").Error)) do

        local conn = getrawmetatable(connection)
        local old = conn and conn.__index
        
        if PROTOSMASHER_LOADED ~= nil then setwriteable(conn) else setReadOnly(conn, false) end
        
        if old then
            conn.__index = newcclosure(function(t, k)
                if k == "Connected" then
                    return true
                end
                return old(t, k)
            end)
        end

        if PROTOSMASHER_LOADED ~= nil then
            setReadOnly(conn)
            connection:Disconnect()
        else
            setReadOnly(conn, true)
            connection:Disable()
        end
    end
end

useMethods(globalMethods)

local HttpService = game:GetService("HttpService")
local releaseInfo = HttpService:JSONDecode(game:HttpGetAsync("https://api.github.com/repos/" .. user .. "/Hydroxide/releases"))[1]
-- Include published_at so replacing a tag/release busts the local module cache.
local releaseVersion = tostring(releaseInfo.tag_name) .. ":" .. tostring(releaseInfo.published_at or releaseInfo.id or "")

local hasFolderFunctions = (isFolder and makeFolder) ~= nil
local hasFileFunctions = (readFile and writeFile) ~= nil

local function createFolder(path)
    if hasFolderFunctions and not isFolder(path) then
        makeFolder(path)
    end
end

local function ensureCacheFolders()
    if not hasFolderFunctions then
        return
    end

    createFolder("hydroxide")
    createFolder("hydroxide/user")
    createFolder("hydroxide/user/" .. user)
    createFolder("hydroxide/user/" .. user .. "/methods")
    createFolder("hydroxide/user/" .. user .. "/modules")
    createFolder("hydroxide/user/" .. user .. "/objects")
    createFolder("hydroxide/user/" .. user .. "/ui")
    createFolder("hydroxide/user/" .. user .. "/ui/controls")
    createFolder("hydroxide/user/" .. user .. "/ui/modules")
end

local function cachePath(asset)
    if hasFolderFunctions then
        return "hydroxide/user/" .. user .. "/" .. asset .. ".lua"
    end

    return "hydroxide-" .. user .. "-" .. asset:gsub("/", "-") .. ".lua"
end

local function isValidSource(content)
    return type(content) == "string" and #content > 0
end

local function fetchRemoteSource(asset)
    local url = ("https://raw.githubusercontent.com/%s/Hydroxide/%s/%s.lua"):format(user, branch, asset)
    local ok, content = pcall(game.HttpGetAsync, game, url)

    if ok and isValidSource(content) then
        return content
    end

    error(("<OH> Failed to fetch '%s' from %s (%s)"):format(asset, url, tostring(content)), 0)
end

local function readCachedSource(path)
    if not hasFileFunctions then
        return nil
    end

    if isFile and not isFile(path) then
        return nil
    end

    local ok, content = pcall(readFile, path)
    if ok and isValidSource(content) then
        return content
    end

    return nil
end

local function writeCachedSource(path, content)
    if hasFileFunctions and isValidSource(content) then
        pcall(writeFile, path, content)
    end
end

local cachedVersion = hasFileFunctions and select(2, pcall(readFile, "__oh_version.txt")) or nil
local useDiskCache = hasFileFunctions and cachedVersion == releaseVersion

if hasFileFunctions and not useDiskCache then
    ensureCacheFolders()
    pcall(writeFile, "__oh_version.txt", releaseVersion)
end

function environment.import(asset)
    if importCache[asset] then
        return unpack(importCache[asset])
    end

    local assets

    if asset:find("rbxassetid://") then
        assets = { game:GetObjects(asset)[1] }
    elseif web then
        local content

        if useDiskCache then
            content = readCachedSource(cachePath(asset))
        end

        if not isValidSource(content) then
            content = fetchRemoteSource(asset)
            writeCachedSource(cachePath(asset), content)
        end

        local compiled, result = loadstring(content, asset .. ".lua")
        if not compiled then
            error(("<OH> Failed to compile '%s': %s"):format(asset, tostring(result)), 0)
        end

        assets = { compiled() }
    else
        local content = readFile("hydroxide/" .. asset .. ".lua")
        assert(isValidSource(content), "<OH> Local file missing or empty: hydroxide/" .. asset .. ".lua")
        assets = { loadstring(content, asset .. ".lua")() }
    end

    importCache[asset] = assets
    return unpack(assets)
end

useMethods({ import = environment.import })

useMethods(import("methods/string"))
useMethods(import("methods/table"))
useMethods(import("methods/userdata"))
useMethods(import("methods/environment"))

--import("ui/main")
