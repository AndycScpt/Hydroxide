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
local eventSet = false

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

local function getCallerFunction()
    local success, info = pcall(getInfo, 3)
    if success and type(info) == "table" then
        return info.func
    end
end

local function processRemote(instance, vargs)
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
            func = getCallerFunction()
        }

        remote:IncrementCalls(call)
        remoteDataEvent:Fire(instance, call)
    end

    return remoteBlocked or argsBlocked
end

local nmcTrampoline
nmcTrampoline = hookMetaMethod(game, "__namecall", function(...)
    local instance = ...

    if typeof(instance) ~= "Instance" then
        return nmcTrampoline(...)
    end

    local method = normalizeMethod(getNamecallMethod())

    if remotesViewing[instance.ClassName] and instance ~= remoteDataEvent and remoteMethods[method] then
        local vargs = packCallArgs(...)

        if processRemote(instance, vargs) then
            return
        end
    end

    return nmcTrampoline(...)
end)

local pcall = pcall

local function checkPermission(instance)
    if (instance.ClassName) then end
end

for className, hook in pairs(methodHooks) do
    if hook then
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

            if instance.ClassName == className and remotesViewing[instance.ClassName] and instance ~= remoteDataEvent then
                local vargs = packCallArgs(...)

                if processRemote(instance, vargs) then
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
