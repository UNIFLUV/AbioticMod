-- Read metadata and object references only. Never invoke gameplay/input/save events.
local Probe = {}
Probe.__index = Probe
local function valid(v) return v ~= nil and v:IsValid() end
local function relevant(name)
    name = name:lower()
    for _, part in ipairs({'inp', 'invent', 'interact', 'container', 'loot', 'hud', 'controller', 'character', 'trait', 'local', 'firstperson', 'montage', 'setup'}) do
        if name:find(part, 1, true) then return true end
    end
    return false
end
function Probe.new(api) return setmetatable({api = api, seen = {}}, Probe) end
function Probe:object(label, object)
    if not valid(object) then self.api.log('ROUTE ' .. label .. ' NONE'); return end
    self.api.log('ROUTE ' .. label .. ' ' .. object:GetFullName())
    local class, refs = object:GetClass(), 0
    for _ = 1, 4 do
        if not valid(class) then break end
        class:ForEachProperty(function(p)
            local key = p:GetFName():ToString()
            if relevant(key) and p:GetFullName():match('^ObjectProperty ') then
                refs = refs + 1
                if refs > 64 then return true end
                local ok, value = pcall(function() return object[key] end)
                if ok then
                    local read, name = pcall(function() return valid(value) and value:GetFullName() or 'NONE' end)
                    if read then self.api.log('ROUTE REF ' .. label .. '.' .. key .. ' -> ' .. name) end
                end
            end
        end)
        if refs > 64 then self.api.log('ROUTE reference scan truncated: ' .. label); break end
        local id = class:GetAddress()
        if not self.seen[id] then
            self.seen[id] = true
            local count = 0
            class:ForEachFunction(function(func)
                if relevant(func:GetFName():ToString()) then
                    count = count + 1
                    if count > 60 then return true end
                    self.api.log('ROUTE FUNCTION ' .. func:GetFullName())
                    local n = 0
                    func:ForEachProperty(function(p)
                        n = n + 1
                        if n > 12 then self.api.log('ROUTE parameters truncated'); return true end
                        self.api.log('ROUTE PARAM ' .. p:GetFullName())
                    end)
                end
            end)
            if count > 60 then self.api.log('ROUTE function scan truncated') end
        end
        class = class:GetSuperStruct()
    end
end
function Probe:capture()
    local _, first, second = self.api.pair()
    local h = self.api.huds() or {}
    self.api.log('ROUTE BEGIN: input handoff snapshot')
    for i, pc in ipairs({first, second}) do
        for _, entry in ipairs({{'Controller', pc}, {'Pawn', pc.Pawn}, {'NativeHUD', pc.MyHUD}, {'State', pc.PlayerState}}) do
            local ok, message = pcall(function() self:object(entry[1] .. (i-1), entry[2]) end)
            if not ok then self.api.log('ROUTE partial scan: ' .. tostring(message)) end
        end
    end
    for i, widget in pairs({[0] = h.main, [1] = h.guest}) do
        local ok, message = pcall(function() self:object('HUD' .. i, widget) end)
        if not ok then self.api.log('ROUTE partial HUD scan: ' .. tostring(message)) end
    end
    self.api.log('ROUTE END')
end
return Probe
