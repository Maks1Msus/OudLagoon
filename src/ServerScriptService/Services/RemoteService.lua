local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(
    ReplicatedStorage.Shared.Config.GameConfig
)

local RemoteService = {}

local Events = {}
local Functions = {}

local EVENT_NAMES = {
    "ProfileUpdated",     -- сервер -> клиент
    "CombatRequest",      -- клиент -> сервер (см. CombatService)
    "CombatFeedback",     -- сервер -> клиент (попадания, числа урона)
    "AbilityRequest",     -- клиент -> сервер (пока без обработчика)
    "InteractionRequest", -- клиент -> сервер (пока без обработчика)
    "DebugRequest",       -- клиент -> сервер (только Studio, см. DebugService)
    "StatAllocationRequest",
}

local FUNCTION_NAMES = {
    "RequestProfile",     -- клиент запрашивает свой профиль после загрузки UI
}

-- ВАЛИДАТОРЫ ------------------------------------------------------------
-- Клиенту нельзя доверять: любой аргумент может быть чем угодно (nil, NaN, огромная строка).

RemoteService.Check = {
    String = function(value, maxLength)
        return type(value) == "string" and #value <= (maxLength or 64)
    end,

    Number = function(value, min, max)
        return type(value) == "number"
            and value == value -- отсеивает NaN
            and value >= (min or -1e9)
            and value <= (max or 1e9)
    end,
}

-- ЛИМИТ ЧАСТОТЫ ---------------------------------------------------------

local RateState = {} -- [player][remoteName] = { Start, Count }

local function IsAllowed(player, remoteName, limitPerSecond)
    local now = os.clock()

    local perPlayer = RateState[player]

    if not perPlayer then
        perPlayer = {}
        RateState[player] = perPlayer
    end

    local state = perPlayer[remoteName]

    if not state or now - state.Start >= 1 then
        state = { Start = now, Count = 0 }
        perPlayer[remoteName] = state
    end

    state.Count += 1

    return state.Count <= limitPerSecond
end

-- СОЗДАНИЕ REMOTES ------------------------------------------------------

local function GetOrCreate(parent, className, name)
    local instance = parent:FindFirstChild(name)

    if not instance then
        instance = Instance.new(className)
        instance.Name = name
        instance.Parent = parent
    end

    assert(
        instance:IsA(className),
        name .. " must be a " .. className
    )

    return instance
end

function RemoteService:Init()
    local remotes = GetOrCreate(ReplicatedStorage, "Folder", "Remotes")
    local eventsFolder = GetOrCreate(remotes, "Folder", "Events")
    local functionsFolder = GetOrCreate(remotes, "Folder", "Functions")

    for _, name in ipairs(EVENT_NAMES) do
        Events[name] = GetOrCreate(eventsFolder, "RemoteEvent", name)
    end

    for _, name in ipairs(FUNCTION_NAMES) do
        Functions[name] = GetOrCreate(functionsFolder, "RemoteFunction", name)
    end

    Players.PlayerRemoving:Connect(function(player)
        RateState[player] = nil
    end)

    print("[RemoteService] Remotes initialized")
end

function RemoteService:GetEvent(eventName)
    local event = Events[eventName]

    assert(event, "Unknown RemoteEvent: " .. tostring(eventName))

    return event
end

function RemoteService:GetFunction(functionName)
    local remoteFunction = Functions[functionName]

    assert(remoteFunction, "Unknown RemoteFunction: " .. tostring(functionName))

    return remoteFunction
end

-- ПОДПИСКА НА ВЫЗОВЫ КЛИЕНТА -------------------------------------------
-- options.RateLimit - максимум вызовов в секунду от одного игрока
-- options.Validate  - function(...) -> boolean, проверка аргументов (без player)
-- handler           - function(player, ...)

function RemoteService:OnEvent(eventName, options, handler)
    options = options or {}

    local event = self:GetEvent(eventName)
    local limit = options.RateLimit or GameConfig.DefaultRemoteRateLimit
    local validate = options.Validate

    return event.OnServerEvent:Connect(function(player, ...)
        if not IsAllowed(player, eventName, limit) then
            return
        end

        if validate then
            local ok, valid = pcall(validate, ...)

            if not ok or not valid then
                warn(
                    "[RemoteService] Invalid payload for",
                    eventName,
                    "from",
                    player.Name
                )
                return
            end
        end

        local ok, err = pcall(handler, player, ...)

        if not ok then
            warn("[RemoteService] Handler error in", eventName, err)
        end
    end)
end

-- У RemoteFunction может быть только один обработчик.
-- Сервер НИКОГДА не должен вызывать InvokeClient: клиент может не ответить, и поток зависнет.
function RemoteService:OnFunction(functionName, options, handler)
    options = options or {}

    local remoteFunction = self:GetFunction(functionName)
    local limit = options.RateLimit or GameConfig.DefaultRemoteRateLimit
    local validate = options.Validate

    remoteFunction.OnServerInvoke = function(player, ...)
        if not IsAllowed(player, functionName, limit) then
            return nil
        end

        if validate then
            local ok, valid = pcall(validate, ...)

            if not ok or not valid then
                return nil
            end
        end

        local ok, result = pcall(handler, player, ...)

        if not ok then
            warn("[RemoteService] Handler error in", functionName, result)
            return nil
        end

        return result
    end
end

return RemoteService