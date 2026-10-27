-- v0.7.2: confirmed controller/HUD and pawn/inventory UI references only.
local Link = {}
Link.__index = Link
local function valid(v) return v ~= nil and v:IsValid() end
local function same(a, b) return valid(a) and valid(b) and a:GetAddress() == b:GetAddress() end
local function field(object, name)
    local class = object:GetClass()
    for _ = 1, 5 do
        if not valid(class) then break end
        local found = false
        class:ForEachProperty(function(p)
            if p:GetFName():ToString() == name and p:GetFullName():match('^ObjectProperty ') then found = true end
        end)
        if found then return true end
        class = class:GetSuperStruct()
    end
    return false
end
function Link.new(api) return setmetatable({api = api}, Link) end
function Link:bind()
    local _, first, second = self.api.pair()
    local h = self.api.huds()
    assert(h and valid(h.main) and valid(h.guest), 'Two mod-owned HUDs are required.')
    assert(same(h.main:GetOwningPlayer(), first) and same(h.guest:GetOwningPlayer(), second), 'HUD owner changed.')
    assert(valid(second.Pawn) and not same(first.Pawn, second.Pawn), 'Separate guest pawn required.')
    assert(field(second, 'PlayerHUDRef') and field(h.guest, 'OwningCharacter'), 'HUD field types not confirmed.')
    local inventory, primary = h.guest.W_PlayerInventory_Main, h.main.W_PlayerInventory_Main
    assert(valid(inventory) and same(inventory:GetOwningPlayer(), second), 'Guest inventory widget owner not confirmed.')
    assert(field(second.Pawn, 'InventoryReference'), 'Pawn inventory UI field type not confirmed.')
    local old_inventory = second.Pawn.InventoryReference
    assert(not valid(old_inventory) or same(old_inventory, primary) or same(old_inventory, inventory), 'Unknown guest inventory UI reference; left unchanged.')
    local old, character = second.PlayerHUDRef, h.guest.OwningCharacter
    assert(not valid(old) or same(old, h.main) or same(old, h.guest), 'Unknown guest HUD reference; left unchanged.')
    assert(not valid(character) or same(character, first.Pawn) or same(character, second.Pawn), 'Unknown guest HUD character; left unchanged.')
    if self.record then
        assert(same(self.record.pc, second) and same(self.record.hud, h.guest), 'Restart after a controller/HUD change.')
        assert(same(self.record.pawn, second.Pawn) and same(self.record.inventory, inventory), 'Restart after a pawn/inventory widget change.')
    else
        self.record = {pc = second, hud = h.guest, old = valid(old) and not same(old, h.guest) and old or nil, character = valid(character) and character or nil}
        self.record.pawn, self.record.inventory = second.Pawn, inventory
        self.record.old_inventory = valid(old_inventory) and not same(old_inventory, inventory) and old_inventory or nil
    end
    local ok, message = pcall(function()
        h.guest.OwningCharacter = second.Pawn
        second.PlayerHUDRef = h.guest
        second.Pawn.InventoryReference = inventory
        assert(same(second.PlayerHUDRef, h.guest) and same(h.guest.OwningCharacter, second.Pawn), 'HUD link write not confirmed.')
        assert(same(second.Pawn.InventoryReference, inventory), 'Inventory UI link write not confirmed.')
    end)
    if not ok then self:restore(); error(message) end
    self.api.log('HUDLINK guest PlayerHUDRef and OwningCharacter verified; no local-character or input hooks installed.')
    self.api.log('INVLINK guest Pawn.InventoryReference matches its own inventory widget; verify Tab/container in-game.')
end
function Link:restore()
    local r = self.record
    if not r then return end
    if valid(r.pawn) and same(r.pawn.InventoryReference, r.inventory) then
        r.pawn.InventoryReference = valid(r.old_inventory) and r.old_inventory or nil
    end
    if valid(r.pc) and same(r.pc.PlayerHUDRef, r.hud) then r.pc.PlayerHUDRef = valid(r.old) and r.old or nil end
    if valid(r.hud) and valid(r.pc) and same(r.hud.OwningCharacter, r.pc.Pawn) then
        r.hud.OwningCharacter = valid(r.character) and r.character or nil
    end
    self.record = nil
end
function Link:diagnose()
    local _, first, second = self.api.pair()
    local h = self.api.huds()
    self.api.log('HUDLINK guest HUD match=' .. tostring(h and same(second.PlayerHUDRef, h.guest) or false))
    self.api.log('INVLINK guest inventory UI match=' .. tostring(h and valid(h.guest) and same(second.Pawn.InventoryReference, h.guest.W_PlayerInventory_Main) or false))
    for i, pc in ipairs({first, second}) do
        self.api.log('HUDLINK P' .. (i-1) .. ' received=' .. tostring(pc.ClientHasRecievedCharacter) .. '; traits=' .. tostring(pc.HasCompletedTraitSelect))
        for _, object in ipairs({pc, pc.Pawn}) do
            if valid(object) then
                local count, class = 0, object:GetClass()
                class:ForEachFunction(function(func)
                    local name = func:GetFName():ToString():lower()
                    if name:find('inp', 1, true) == 1 or name:find('inventory', 1, true) or name:find('interact', 1, true) then
                        count = count + 1
                        if count > 40 then self.api.log('HUDLINK input scan truncated'); return true end
                        self.api.log('HUDLINK INPUT P' .. (i-1) .. ' ' .. func:GetFullName())
                    end
                end)
            end
        end
    end
end
return Link
