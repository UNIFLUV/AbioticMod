local Link = require('hud_link')
local serial, passed = 0, 0
local function object(schema)
    serial = serial + 1
    local o, class = {id = serial}, {}
    function o:IsValid() return true end
    function o:GetAddress() return self.id end
    function o:GetClass() return class end
    function class:IsValid() return true end
    function class:GetSuperStruct() return nil end
    function class:ForEachProperty(callback)
        for name, kind in pairs(schema or {}) do
            local p = {}
            function p:GetFName() return {ToString = function() return name end} end
            function p:GetFullName() return kind .. ' Fixture:' .. name end
            callback(p)
        end
    end
    return o
end
local function fixture()
    local f = {host = object(), guest = object({PlayerHUDRef = 'ObjectProperty'}), main = object(), hud = object({OwningCharacter = 'ObjectProperty'})}
    f.host.Pawn, f.guest.Pawn = object(), object({InventoryReference = 'ObjectProperty'})
    f.main.W_PlayerInventory_Main, f.hud.W_PlayerInventory_Main = object(), object()
    function f.main.W_PlayerInventory_Main:GetOwningPlayer() return f.host end
    function f.hud.W_PlayerInventory_Main:GetOwningPlayer() return f.guest end
    f.host.Pawn.InventoryReference = f.main.W_PlayerInventory_Main
    f.host.PlayerHUDRef, f.hud.OwningCharacter = f.main, f.host.Pawn
    f.host.PlayerSaveID, f.guest.PlayerSaveID = 'SAME', 'SAME'
    function f.main:GetOwningPlayer() return f.host end
    function f.hud:GetOwningPlayer() return f.guest end
    f.link = Link.new({pair = function() return {}, f.host, f.guest end,
        huds = function() return {main = f.main, guest = f.hud} end, log = function() end})
    return f
end
local function test(name, fn) fn(); passed = passed + 1; print('PASS ' .. name) end
test('missing guest HUD cache is linked without changing host or save IDs', function()
    local f = fixture(); f.link:bind()
    assert(f.guest.PlayerHUDRef == f.hud and f.hud.OwningCharacter == f.guest.Pawn)
    assert(f.guest.Pawn.InventoryReference == f.hud.W_PlayerInventory_Main)
    assert(f.host.Pawn.InventoryReference == f.main.W_PlayerInventory_Main)
    assert(f.host.PlayerHUDRef == f.main and f.host.PlayerSaveID == 'SAME' and f.guest.PlayerSaveID == 'SAME')
end)
test('a confirmed stale host cache is restored during teardown', function()
    local f = fixture(); f.guest.PlayerHUDRef = f.main
    f.link:bind(); f.link:bind(); f.link:restore()
    assert(f.guest.PlayerHUDRef == f.main and f.hud.OwningCharacter == f.host.Pawn)
end)
test('foreign cache is refused before the HUD character changes', function()
    local f = fixture(); local other = object(); f.guest.PlayerHUDRef = other
    assert(not pcall(function() f.link:bind() end))
    assert(f.guest.PlayerHUDRef == other and f.hud.OwningCharacter == f.host.Pawn)
end)
test('wrong widget owner cannot be assigned to the guest controller', function()
    local f = fixture(); function f.hud:GetOwningPlayer() return f.host end
    assert(not pcall(function() f.link:bind() end)); assert(f.guest.PlayerHUDRef == nil)
end)
test('teardown preserves a cache replaced by another system', function()
    local f = fixture(); f.link:bind(); local other = object(); f.guest.PlayerHUDRef = other
    f.link:restore(); assert(f.guest.PlayerHUDRef == other)
end)
test('a prelinked mod widget is not left referenced after teardown', function()
    local f = fixture(); f.guest.PlayerHUDRef = f.hud
    f.link:bind(); f.link:restore(); assert(f.guest.PlayerHUDRef == nil)
end)
test('foreign pawn inventory UI reference is refused before any writes', function()
    local f = fixture(); local foreign = object(); f.guest.Pawn.InventoryReference = foreign
    assert(not pcall(function() f.link:bind() end))
    assert(f.guest.Pawn.InventoryReference == foreign and f.guest.PlayerHUDRef == nil and f.hud.OwningCharacter == f.host.Pawn)
end)
test('inventory widget owned by host is never bound to guest pawn', function()
    local f = fixture(); function f.hud.W_PlayerInventory_Main:GetOwningPlayer() return f.host end
    assert(not pcall(function() f.link:bind() end)); assert(f.guest.PlayerHUDRef == nil)
end)
test('inventory teardown clears only the reference assigned by the mod', function()
    local f = fixture(); f.link:bind(); f.link:restore()
    assert(f.guest.Pawn.InventoryReference == nil)
    f.link:bind(); local other = object(); f.guest.Pawn.InventoryReference = other
    f.link:restore(); assert(f.guest.Pawn.InventoryReference == other)
end)
test('unsupported property types prevent all writes', function()
    local f = fixture(); f.guest = object({PlayerHUDRef = 'IntProperty'}); f.guest.Pawn = object()
    assert(not pcall(function() f.link:bind() end)); assert(f.hud.OwningCharacter == f.host.Pawn)
end)
print(passed .. ' HUD-link tests passed (mock API; actual game menus and animation unverified).')
