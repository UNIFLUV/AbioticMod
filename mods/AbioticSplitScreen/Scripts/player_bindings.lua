local Runtime = {}
Runtime.__index = Runtime
local function valid(value) return value ~= nil and value:IsValid() end
local function same(a, b) return valid(a) and valid(b) and a:GetAddress() == b:GetAddress() end
local function visible(value) return value == 0 or value == 3 or value == 4 end

function Runtime.new(api)
    return setmetatable({ api = api, hook_paths = {}, fields = {}, watch_id = 0, actions = {}, last_action = {}, host_action = {}, key_ticket = {} }, Runtime)
end

function Runtime:properties(object)
    local class = object:GetClass()
    local id = class:GetAddress()
    if self.fields[id] then return self.fields[id] end
    local fields = {}
    for _ = 1, 4 do
        if not valid(class) then break end
        class:ForEachProperty(function(property)
            fields[property:GetFName():ToString()] = property:GetFullName()
        end)
        class = class:GetSuperStruct()
    end
    self.fields[id] = fields
    return fields
end

function Runtime:set_reference(object, field, expected, primary, label)
    if not self:properties(object)[field] then return end
    local old = object[field]
    if same(old, expected) then return end
    if valid(old) and not same(old, primary) then
        self.api.log("BIND skipped foreign reference: " .. label .. "." .. field)
        return
    end
    object[field] = expected
    assert(same(object[field], expected), "Reference write was not confirmed: " .. field)
    self.api.log("BIND repaired " .. label .. "." .. field)
end

local function ownership_field(field)
    local name = field:lower()
    for _, word in ipairs({ "target", "selected", "other", "last", "hover", "looking" }) do
        if name:find(word, 1, true) then return false end
    end
    return name:match("^own") or name:match("^my") or name:match("^local") or
        name == "cachedcharacter" or name == "cachedpawn" or name == "cachedcontroller" or
        name == "pc" or name == "pcref" or name == "controllerref" or name == "playercontrollerref"
end

function Runtime:remap_cached(object, replacements, label)
    for field, description in pairs(self:properties(object)) do
        if description:match("^ObjectProperty ") then
            local old = object[field]
            for _, replacement in ipairs(replacements) do
                if same(old, replacement.from) and (replacement.hud or ownership_field(field)) then
                    local excluded = false
                    for _, word in ipairs({ "target", "selected", "other", "last", "primary", "host", "first", "player0", "global" }) do
                        if field:lower():find(word, 1, true) then excluded = true end
                    end
                    if not excluded then
                        object[field] = replacement.to
                        assert(same(object[field], replacement.to), "Cached binding write failed: " .. field)
                        self.api.log("BIND remapped " .. label .. "." .. field)
                    end
                end
            end
        end
    end
end

function Runtime:repair()
    local _, first, second = self.api.pair()
    assert(valid(first.Pawn) and valid(second.Pawn) and not same(first.Pawn, second.Pawn), "Two separate pawns are required.")
    self.guest_controller = second
    self.host_controller = first
    self:set_reference(second, "MyPlayerCharacter", second.Pawn, first.Pawn, "Controller1")
    self:set_reference(second, "PlayerCharacter", second.Pawn, first.Pawn, "Controller1")
    local replacements = { { from = first, to = second }, { from = first.Pawn, to = second.Pawn } }
    if valid(first.PlayerState) and valid(second.PlayerState) and not same(first.PlayerState, second.PlayerState) then
        replacements[#replacements + 1] = { from = first.PlayerState, to = second.PlayerState }
    end
    local state = self.api.huds()
    if state and valid(state.main) and valid(state.guest) then
        assert(same(state.main:GetOwningPlayer(), first) and same(state.guest:GetOwningPlayer(), second), "HUD ownership changed.")
        self:set_reference(state.guest, "OwningCharacter", second.Pawn, first.Pawn, "HUD1")
        replacements[#replacements + 1] = { from = state.main, to = state.guest, hud = true }
        self:remap_cached(state.guest, replacements, "HUD1")
    end
    self:remap_cached(second, replacements, "Controller1")
    self:remap_cached(second.Pawn, replacements, "Pawn1")
end

function Runtime:clock()
    local context = self.api.pair()
    local time = context.statics:GetRealTimeSeconds(context.world)
    assert(type(time) == "number", "Input event clock is unavailable.")
    return time
end

function Runtime:install_input_hooks()
    if type(self.api.hook) ~= "function" or self.api.fname == nil then
        self.api.log("INPUT fallback API unavailable; native input left unchanged.")
        return
    end
    local _, _, second = self.api.pair()
    local candidates = { inventory = {}, escape = {} }
    second:GetClass():ForEachFunction(function(func)
        local name = func:GetFName():ToString():lower()
        if name:find("inpactevt_", 1, true) == 1 and name:find("inputactionevent", 1, true) then
            if name:find("inpactevt_inventory_", 1, true) == 1 then candidates.inventory[#candidates.inventory + 1] = func end
            if name:find("inpactevt_escapemenu_", 1, true) == 1 then candidates.escape[#candidates.escape + 1] = func end
        end
    end)
    for kind, functions in pairs(candidates) do
        if not self.actions[kind] then
            local ok, message = pcall(function()
                assert(#functions == 1, "A unique generated input event was not found.")
                local func, count = functions[1], 0
                func:ForEachProperty(function(property)
                    count = count + 1
                    assert(property:GetFName():ToString() == "Key" and property:GetFullName():match("^StructProperty "),
                        "Expected one generated FKey parameter.")
                end)
                assert(count == 1, "Input event signature was not confirmed.")
                local path = func:GetFullName():gsub("^Function ", "")
                self.api.hook(path, function(context)
                    local ok = pcall(function()
                        local controller = context:get()
                        if same(controller, self.guest_controller) then self.last_action[kind] = self:clock()
                        elseif same(controller, self.host_controller) and self.api.guest_active and self.api.guest_active() then self.host_action[kind] = self:clock() end
                    end)
                end)
                self.actions[kind] = func
                self.api.log("INPUT guarded fallback registered: " .. path)
            end)
            if not ok then self.api.log("INPUT " .. kind .. " fallback skipped: " .. tostring(message)) end
        end
    end
end

function Runtime:key_action(kind)
    if self.pause or not self.api.guest_active or not self.api.guest_active() or not self.actions[kind] then return end
    local context, _, second = self.api.pair()
    if context.statics:GetPlayerControllerID(second) ~= 0 then return end
    local pressed = self:clock()
    self.key_ticket[kind] = (self.key_ticket[kind] or 0) + 1
    local ticket = self.key_ticket[kind]
    self.api.delay(120, function()
        self.api.game_thread(function()
            local ok, message = pcall(function()
                if self.pause or self.key_ticket[kind] ~= ticket or not self.api.guest_active() then return end
                local active, _, current = self.api.pair()
                if not same(current, second) then return end
                if active.statics:GetPlayerControllerID(current) ~= 0 then return end
                if (self.last_action[kind] or -math.huge) >= pressed - 0.05 then
                    self.api.log("INPUT native guest " .. kind .. " action observed; fallback skipped.")
                    return
                end
                if (self.host_action[kind] or -math.huge) >= pressed - 0.05 then
                    self.api.log("INPUT action reached the host during guest handoff; fallback skipped to avoid toggling both players' menus.")
                    return
                end
                local key = { KeyName = self.api.fname(kind == "inventory" and "Tab" or "Escape") }
                self.actions[kind](second, key)
                self.api.log("INPUT forwarded " .. kind .. " action to the guest controller. Verify the menu in-game.")
            end)
            if not ok then self.api.log("INPUT fallback stopped: " .. tostring(message)) end
        end)
    end)
end

function Runtime:refresh_mappings()
    local context, first, second = self.api.pair()
    if not valid(self.api.find("/Script/AbioticFactor.AbioticGameInstance:MappingsChanged")) then
        self.api.log("BIND MappingsChanged unavailable; native input refresh skipped.")
        return
    end
    for _, controller in ipairs({ first, second }) do context.instance:MappingsChanged(controller) end
    self.api.log("BIND native input-mapping refresh requested for both local controllers.")
end

function Runtime:install_local_hooks()
    if type(self.api.hook) ~= "function" then self.api.log("BIND predicate hook API unavailable."); return end
    local paths = {
        "/Script/AbioticFactor.AbioticCharacter:IsLocalAbioticCharacter",
        "/Game/Blueprints/Characters/Abiotic_PlayerCharacter.Abiotic_PlayerCharacter_C:IsLocalCharacter",
        "/Game/Blueprints/Characters/Abiotic_Character_ParentBP.Abiotic_Character_ParentBP_C:Is Locally Controlled Abiotic Character",
    }
    for _, path in ipairs(paths) do
        if not self.hook_paths[path] then
            local ok, message = pcall(function()
                local func = self.api.find(path)
                assert(valid(func), "function unavailable")
                local bool_return = false
                func:ForEachProperty(function(property)
                    if property:GetFName():ToString() == "ReturnValue" and property:GetFullName():match("^BoolProperty ") then bool_return = true end
                end)
                assert(bool_return, "boolean return signature not confirmed")
                local callback = function(context)
                    local eligible, result = pcall(function()
                        local pawn = context:get()
                        local second = self.guest_controller
                        if not valid(second) then return false end
                        return same(pawn, second.Pawn) and self:separate_save_namespace() and pawn:IsLocallyControlled() == true
                    end)
                    if eligible and result then return true end
                end
                if path:sub(1, 8) == "/Script/" then self.api.hook(path, function() end, callback)
                else self.api.hook(path, callback) end
                self.hook_paths[path] = true
                self.api.log("BIND scoped local-character predicate hook installed: " .. path)
            end)
            if not ok then self.api.log("BIND predicate hook skipped: " .. path .. ": " .. tostring(message)) end
        end
    end
    if not self:separate_save_namespace() then
        self.api.log("PROFILE local-predicate overrides withheld: guest save ID is empty, shared or unreadable. No profile keys were changed.")
    end
end

local function private_string(value)
    if type(value) == "string" then return value end
    if value ~= nil then
        local ok, text = pcall(function() return value:ToString() end)
        if ok and type(text) == "string" then return text end
    end
end

function Runtime:separate_save_namespace()
    local ok, result = pcall(function()
        local first, second = self.host_controller, self.guest_controller
        if not valid(first) or not valid(second) or not valid(first.PlayerState) or not valid(second.PlayerState) then return false end
        local host = private_string(first.PlayerState.PlayerSaveID)
        local guest = private_string(second.PlayerState.PlayerSaveID)
        return host ~= nil and guest ~= nil and host ~= "" and guest ~= "" and host ~= guest
    end)
    return ok and result == true
end

function Runtime:snapshot()
    local _, first, second = self.api.pair()
    for index, controller in ipairs({ first, second }) do
        self.api.log("BIND controller " .. (index - 1) .. " cached references:")
        for _, field in ipairs({ "MyPlayerCharacter", "PlayerCharacter" }) do
            local ok, value = pcall(function() return controller[field] end)
            if ok then self.api.log("BIND " .. field .. " matches own pawn=" .. tostring(same(value, controller.Pawn))) end
        end
        for _, field in ipairs({ "HasCompletedTraitSelect", "ClientHasRecievedCharacter" }) do
            local ok, value = pcall(function() return controller[field] end)
            if ok and type(value) == "boolean" then self.api.log("BIND " .. field .. "=" .. tostring(value)) end
        end
        for field, description in pairs(self:properties(controller)) do
            if description:match("^ObjectProperty ") and (field:lower():find("hud", 1, true) or field:lower():find("input", 1, true)) then
                local ok, value = pcall(function() return controller[field] end)
                if ok then
                    local object_ok, text = pcall(function() return valid(value) and value:GetFullName() or "NONE" end)
                    if object_ok then self.api.log("BIND " .. field .. " -> " .. text) end
                end
            end
        end
    end
    for _, field in ipairs({ "UniquePlayerID", "PlayerSaveID" }) do
        local a_ok, a = pcall(function() return private_string(first.PlayerState[field]) end)
        local b_ok, b = pcall(function() return private_string(second.PlayerState[field]) end)
        if a_ok and b_ok and a and b then
            self.api.log("PROFILE " .. field .. " equal=" .. tostring(a == b) .. "; host empty=" .. tostring(a == "") .. "; guest empty=" .. tostring(b == ""))
        else self.api.log("PROFILE " .. field .. " comparison unavailable") end
    end
    local state = self.api.huds()
    if state and valid(state.guest) then
        self.api.log("BIND HUD1.OwningCharacter matches guest=" .. tostring(same(state.guest.OwningCharacter, second.Pawn)))
    end
end

function Runtime:diagnose()
    self:snapshot()
    local _, first, second = self.api.pair()
    local inspected = {}
    local targets = { { "Controller0", first }, { "Controller1", second }, { "Pawn1", second.Pawn }, { "PlayerState1", second.PlayerState } }
    local state = self.api.huds()
    if state then targets[#targets + 1] = { "HUD1", state.guest } end
    for _, entry in ipairs(targets) do
        local label, object = entry[1], entry[2]
        if valid(object) then
            local class = object:GetClass()
            if not inspected[class:GetAddress()] then
                inspected[class:GetAddress()] = true
                local count = 0
                class:ForEachFunction(function(func)
                    count = count + 1
                    if count > 160 then self.api.log("SIGNATURE " .. label .. " truncated"); return true end
                    self.api.log("SIGNATURE " .. label .. " " .. func:GetFullName())
                    local n = 0
                    func:ForEachProperty(function(property)
                        n = n + 1
                        if n > 16 then self.api.log("SIGNATURE parameters truncated"); return true end
                        self.api.log("SIGNATURE PARAM " .. property:GetFullName())
                    end)
                end)
            end
        end
    end
end

function Runtime:transition(callback)
    local previous = self.transitioning
    self.transitioning = true
    local ok, message = pcall(callback)
    self.transitioning = previous
    if not ok then error(message) end
end

function Runtime:leave_pause(skip_layout)
    self:transition(function() self:_leave_pause(skip_layout) end)
end

function Runtime:_leave_pause(skip_layout)
    local record = self.pause
    if not record then return end
    local context = self.api.context and self.api.context() or self.api.pair()
    assert(same(record.world, context.world), "Pause world changed; old widgets will not be restored into the new world.")
    if record.paused_by_us and context.statics:IsGamePaused(context.world) then
        assert(context.statics:SetGamePaused(context.world, false) == true, "The engine refused to unpause.")
        assert(context.statics:IsGamePaused(context.world) == false, "Unpause was not confirmed.")
        record.paused_by_us = false
    end
    if not skip_layout then
        local visibility = record.escape:GetVisibility()
        record.hud:RemoveFromParent()
        assert(record.hud:AddToPlayerScreen(record.z) == true, "Could not restore player-screen HUD.")
        record.subsystem:SetWidgetSlot(record.hud, record.slot)
        record.escape:SetVisibility(visibility)
    end
    if record.warning and valid(record.warning.widget) then record.warning.widget:SetVisibility(record.warning.visibility) end
    self.pause = nil
    if self.api.huds() then
        local repaired, message = pcall(function() self:repair() end)
        if not repaired then self.api.log("BIND post-menu repair deferred: " .. tostring(message)) end
    end
    self.api.log("PAUSE player HUD layout restored; mod-owned pause released.")
end

function Runtime:enter_pause(hud, escape, owner)
    self:transition(function() self:_enter_pause(hud, escape, owner) end)
end

function Runtime:_enter_pause(hud, escape, owner)
    local context = self.api.pair()
    local subsystem = self.api.find_first("GameViewportSubsystem")
    assert(valid(subsystem), "Viewport subsystem unavailable for pause layout.")
    local slot = subsystem:GetWidgetSlot(hud)
    assert(type(slot.ZOrder) == "number", "Pause HUD Z order unavailable.")
    local visibility = escape:GetVisibility()
    local record = { hud = hud, escape = escape, owner = owner, world = context.world,
        subsystem = subsystem, slot = slot, z = slot.ZOrder, paused_by_us = false }
    self.pause = record
    local ok, message = pcall(function()
        hud:RemoveFromParent()
        hud:AddToViewport(10000)
        assert(hud:IsInViewport(), "Fullscreen menu insertion was not confirmed.")
        escape:SetVisibility(visibility)
        self:repair()
        if not context.statics:IsGamePaused(context.world) then
            local requested = context.statics:SetGamePaused(context.world, true)
            record.paused_by_us = context.statics:IsGamePaused(context.world) == true
            self.api.log("PAUSE engine request=" .. tostring(requested) .. "; world paused=" .. tostring(record.paused_by_us))
        end
        if context.statics:IsGamePaused(context.world) then
            local warning = escape.GamePausedText
            if valid(warning) then
                record.warning = { widget = warning, visibility = warning:GetVisibility() }
                warning:SetVisibility(1)
            end
        end
        self.api.log("PAUSE Esc menu moved to the full viewport. Verify layout, world freeze and Resume/Esc in-game.")
    end)
    if not ok then
        local restored, restoration_error = pcall(function() self:leave_pause(false) end)
        if not restored then self.api.log("PAUSE rollback failed: " .. tostring(restoration_error)) end
        error(message)
    end
end

function Runtime:poll_pause()
    if self.transitioning then return end
    local state = self.api.huds()
    if not state then if self.pause then self:leave_pause(true) end; return end
    local context, first, second = self.api.pair()
    if self.pause then
        if not same(self.pause.world, context.world) then self.pause = nil; self.api.log("PAUSE old-world state discarded."); return end
        if not visible(self.pause.escape:GetVisibility()) then self:leave_pause(false) end
        return
    end
    for _, entry in ipairs({ { state.main, first }, { state.guest, second } }) do
        local hud, owner = entry[1], entry[2]
        if valid(hud) and same(hud:GetOwningPlayer(), owner) then
            local escape = hud.W_EscapeMenu_Main
            if valid(escape) and visible(escape:GetVisibility()) then self:enter_pause(hud, escape, owner); return end
        end
    end
end

function Runtime:close_pause()
    self:transition(function() self:_close_pause() end)
end

function Runtime:_close_pause()
    if not self.pause then return end
    local record = self.pause
    local context, first, second = self.api.pair()
    assert(same(record.world, context.world) and valid(record.owner) and
        (same(record.owner, first) or same(record.owner, second)), "Pause owner/world changed; restart the game.")
    local closed, message = pcall(function() record.owner:CloseEscapeMenuAndResumeGame() end)
    if not closed then self.api.log("PAUSE native close failed: " .. tostring(message)) end
    if visible(record.escape:GetVisibility()) then
        record.escape:SetVisibility(1)
        self.api.log("PAUSE explicitly hid the owned Esc widget after native close did not hide it.")
    end
    self:leave_pause(false)
    record.owner.bShowMouseCursor = false
    local input_ok, input_error = pcall(function()
        local func = self.api.find("/Script/UMG.WidgetBlueprintLibrary:SetInputMode_GameOnly")
        local library = self.api.find("/Script/UMG.Default__WidgetBlueprintLibrary")
        assert(valid(func) and valid(library), "game-only input API unavailable")
        local has_controller, has_flush = false, false
        func:ForEachProperty(function(property)
            local field = property:GetFName():ToString()
            if field == "PlayerController" then has_controller = true
            elseif field == "bFlushInput" then has_flush = true
            else error("unrecognized game-only input parameter: " .. field) end
        end)
        assert(has_controller, "game-only input signature was not confirmed")
        if has_flush then func(library, record.owner, true) else func(library, record.owner) end
    end)
    if not input_ok then self.api.log("PAUSE input-mode restoration skipped: " .. tostring(input_error)) end
end

function Runtime:watch_pause()
    self.watch_id = self.watch_id + 1
    local ticket = self.watch_id
    local function schedule()
        self.api.delay(150, function()
            if ticket ~= self.watch_id then return end
            self.api.game_thread(function()
                if ticket ~= self.watch_id then return end
                local ok, message = pcall(function() self:poll_pause() end)
                if not ok then
                    self.api.log("PAUSE watch stopped: " .. tostring(message))
                    pcall(function() self:leave_pause(false) end)
                    return
                end
                if self.api.huds() then schedule() end
            end)
        end)
    end
    schedule()
end

function Runtime:stop()
    if self.pause then self:close_pause() end
    self.watch_id = self.watch_id + 1
end

return Runtime
