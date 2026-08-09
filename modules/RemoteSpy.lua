local RemoteSpy = {}
local Remote = import("objects/Remote")

local requiredMethods = {
    ["checkCaller"] = true,
    ["newCClosure"] = true,
    ["hookFunction"] = true,
    ["isReadOnly"] = true,
    ["setReadOnly"] = true,
    ["getInfo"] = true,
    ["getMetatable"] = true,
    ["setClipboard"] = true,
    ["getNamecallMethod"] = true,
    ["getCallingScript"] = true,
    ["hookMetaMethod"] = true,
}

local remoteMethods = {
    FireServer = true,
    InvokeServer = true,
    Fire = true,
    Invoke = true
}

local remotesViewing = {
    RemoteEvent = true,
    UnreliableRemoteEvent = false,
    RemoteFunction = false,
    BindableEvent = false,
    BindableFunction = false
}

local function getInstanceMethod(className, methodName)
    local success, instance = pcall(Instance.new, className)
    if success and typeof(instance) == "Instance" then
        return instance[methodName]
    end
end

local methodHooks = {
    RemoteEvent = getInstanceMethod("RemoteEvent", "FireServer"),
    UnreliableRemoteEvent = getInstanceMethod("UnreliableRemoteEvent", "FireServer"),
    RemoteFunction = getInstanceMethod("RemoteFunction", "InvokeServer"),
    BindableEvent = getInstanceMethod("BindableEvent", "Fire"),
    BindableFunction = getInstanceMethod("BindableFunction", "Invoke")
}

local currentRemotes = {}

local remoteDataEvent = Instance.new("BindableEvent")
-- Cache the Fire function so logging never goes through __namecall (which would
-- clobber getnamecallmethod and make RemoteEvent calls look like :Fire()).
local remoteDataFire = remoteDataEvent.Fire
local eventSet = false

local setNamecallMethod = setnamecallmethod or set_namecall_method

local function connectEvent(callback)
    remoteDataEvent.Event:Connect(callback)

    if not eventSet then
        eventSet = true
    end
end

-- Preserve nil/hole arguments; {select(...)} and table.insert(nil) both drop them.
local function packCallArgs(...)
    local n = select("#", ...) - 1
    local args = { n = n }

    for i = 1, n do
        args[i] = select(i + 1, ...)
    end

    return args
end

local function normalizeMethod(method)
    if type(method) ~= "string" then
        return method
    end

    local lower = method:lower()
    if lower == "fireserver" then
        return "FireServer"
    elseif lower == "invokeserver" then
        return "InvokeServer"
    elseif lower == "fire" then
        return "Fire"
    elseif lower == "invoke" then
        return "Invoke"
    end

    return method
end

local function processRemote(instance, vargs, callFunc)
    local remote = currentRemotes[instance]

    if not remote then
        remote = Remote.new(instance)
        currentRemotes[instance] = remote
    end

    local remoteIgnored = remote.Ignored
    local remoteBlocked = remote.Blocked
    local argsIgnored = remote:AreArgsIgnored(vargs)
    local argsBlocked = remote:AreArgsBlocked(vargs)

    if eventSet and (not remoteIgnored and not argsIgnored) then
        local call = {
            script = getCallingScript((PROTOSMASHER_LOADED ~= nil and 2) or nil),
            args = vargs,
            func = callFunc
        }

        remote:IncrementCalls(call)
        remoteDataFire(remoteDataEvent, instance, call)
    end

    return remoteBlocked or argsBlocked
end

local nmcTrampoline
nmcTrampoline = hookMetaMethod(game, "__namecall", function(...)
    local instance = ...

    if typeof(instance) ~= "Instance" then
        return nmcTrampoline(...)
    end

    local rawMethod = getNamecallMethod()
    local method = normalizeMethod(rawMethod)

    if remotesViewing[instance.ClassName] and instance ~= remoteDataEvent and remoteMethods[method] then
        local vargs = packCallArgs(...)
        local callFunc
        local infoOk, info = pcall(getInfo, 3)
        if infoOk and type(info) == "table" then
            callFunc = info.func
        end

        local blocked = processRemote(instance, vargs, callFunc)

        -- Restore namecall method in case anything during logging clobbered it.
        if setNamecallMethod then
            pcall(setNamecallMethod, rawMethod)
        end

        if blocked then
            return
        end
    end

    return nmcTrampoline(...)
end)

local pcall = pcall

local function checkPermission(instance)
    if (instance.ClassName) then end
end

-- Hook each unique method function once (RemoteEvent/UnreliableRemoteEvent may share FireServer).
local hookedMethods = {}

for className, hook in pairs(methodHooks) do
    if hook and not hookedMethods[hook] then
        hookedMethods[hook] = true

        local allowedClasses = {}
        for otherClass, otherHook in pairs(methodHooks) do
            if otherHook == hook then
                allowedClasses[otherClass] = true
            end
        end

        local originalMethod
        originalMethod = hookFunction(hook, newCClosure(function(...)
            local instance = ...

            if typeof(instance) ~= "Instance" then
                return originalMethod(...)
            end

            do
                local success = pcall(checkPermission, instance)
                if not success then
                    return originalMethod(...)
                end
            end

            local instanceClass = instance.ClassName
            if allowedClasses[instanceClass] and remotesViewing[instanceClass] and instance ~= remoteDataEvent then
                local vargs = packCallArgs(...)
                local callFunc
                local infoOk, info = pcall(getInfo, 3)
                if infoOk and type(info) == "table" then
                    callFunc = info.func
                end

                if processRemote(instance, vargs, callFunc) then
                    return
                end
            end

            return originalMethod(...)
        end))

        oh.Hooks[originalMethod] = hook
    end
end

RemoteSpy.RemotesViewing = remotesViewing
RemoteSpy.CurrentRemotes = currentRemotes
RemoteSpy.ConnectEvent = connectEvent
RemoteSpy.RequiredMethods = requiredMethods
return RemoteSpy
