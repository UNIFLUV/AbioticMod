local Ui = require('inventory_ui')
local serial, passed = 0,0
local function object(schema)
    serial=serial+1
    local o={id=serial}; local class={}
    function o:IsValid() return not self.dead end
    function o:GetAddress() return self.id end
    function o:GetClass() return class end
    function o:GetVisibility() return self.visibility or 1 end
    function class:IsValid() return true end
    function class:GetSuperStruct() return nil end
    function class:ForEachProperty(cb)
        for key,kind in pairs(schema or {}) do
            local p={}
            function p:GetFName() return {ToString=function() return key end} end
            function p:GetFullName() return kind .. ' Fixture:' .. key end
            cb(p)
        end
    end
    return o
end
local function fixture()
    local f={logs={},timers={},modes={},guest=true,closes=0}
    f.first,f.second=object(),object()
    f.first.Pawn,f.second.Pawn=object(),object()
    f.first.bShowMouseCursor,f.second.bShowMouseCursor=false,false
    local function hud(owner)
        local h=object()
        local inv=object({OwningCharacter='ObjectProperty'})
        inv.OwningCharacter=f.first.Pawn
        function inv:GetOwningPlayer() return owner end
        inv.InventoryMain=object(); inv.InventoryMain.visibility=0
        inv.W_Inventory_PlayerBackpack=object({OwningCharacter='ObjectProperty'})
        inv.W_Inventory_PlayerBackpack.OwningCharacter=f.first.Pawn
        function inv.W_Inventory_PlayerBackpack:GetOwningPlayer() return owner end
        h.W_PlayerInventory_Main=inv; h.W_EscapeMenu_Main=object()
        return h
    end
    f.h={main=hud(f.first),guest=hud(f.second)}
    f.second.Pawn.InventoryReference=f.h.guest.W_PlayerInventory_Main
    local library=object()
    local function fn(names,callback)
        local func=object()
        function func:ForEachProperty(cb)
            for _,key in ipairs(names) do
                local p={}; function p:GetFName() return {ToString=function() return key end} end
                function p:GetFullName()
                    local kinds={ForceClose='BoolProperty',InventoryMode='EnumProperty',CraftingBenchesAvailable='ArrayProperty',
                        ContainerInventoryComponent='ObjectProperty',CustomUIKeyboardFocus='BoolProperty'}
                    return (kinds[key] or 'IntProperty')..' Fixture:'..key
                end
                cb(p)
            end
        end
        function func:GetFunctionFlags() return f.closeFlags or 0 end
        return setmetatable(func,{__call=function(_,...) return callback(...) end})
    end
    local gameui=fn({'PlayerController','InWidgetToFocus','InMouseLockMode','bHideCursorDuringCapture','bFlushInput'},function(_,pc,w,lock,hide,flush)
        assert(lock==0 and hide==false and flush==false)
        f.modes[#f.modes+1]={pc=pc,widget=w}
    end)
    local gameonly=fn({'PlayerController','bFlushInput'},function(_,pc)
        f.modes[#f.modes+1]={pc=pc}
    end)
    local close=fn({'ForceClose','InventoryMode','CraftingBenchesAvailable','ContainerInventoryComponent','CustomUIKeyboardFocus','Temp_int_Array_Index_Variable'},
        function(pawn,force,mode,benches,container,focus)
            assert(pawn==f.second.Pawn and force==true and type(mode)=='number')
            assert(type(benches)=='table' and next(benches)==nil and container==nil and focus==false)
            if not f.closeNoop then f.h.guest.W_PlayerInventory_Main.visibility=1 end
            f.closes=f.closes+1; f.closeMode=mode
        end)
    f.closeFunction=close
    f.ui=Ui.new({pair=function() return {},f.first,f.second end, huds=function() return f.h end,
        guest_active=function() return f.guest end, delay=function(_,cb) f.timers[#f.timers+1]=cb end,
        game_thread=function(cb) cb() end, log=function(s) f.logs[#f.logs+1]=s end,
        find=function(path)
            if path:find('Default__WidgetBlueprintLibrary',1,true) then return library end
            if path:find('SetInputMode_GameAndUIEx',1,true) then return gameui end
            if path:find('SetInputMode_GameOnly',1,true) then return gameonly end
            if path:find(':ToggleInventory',1,true) then return close end
        end})
    return f
end
local function test(name,fn) fn(); passed=passed+1; print('PASS '..name) end
test('inventory root and backpack belong to guest before presentation; host unchanged',function()
    local f=fixture(); f.ui:bind()
    assert(f.h.guest.W_PlayerInventory_Main.OwningCharacter==f.second.Pawn)
    assert(f.h.guest.W_PlayerInventory_Main.W_Inventory_PlayerBackpack.OwningCharacter==f.second.Pawn)
    assert(f.h.main.W_PlayerInventory_Main.OwningCharacter==f.first.Pawn)
end)
test('foreign child controller prevents all character writes',function()
    local f=fixture(); function f.h.guest.W_PlayerInventory_Main.W_Inventory_PlayerBackpack:GetOwningPlayer() return f.first end
    assert(not pcall(function() f.ui:bind() end))
    assert(f.h.guest.W_PlayerInventory_Main.OwningCharacter==f.first.Pawn)
end)
test('UI focus goes to guest while shared hardware cursor is visible',function()
    local f=fixture(); f.ui:bind(); f.h.guest.W_PlayerInventory_Main.visibility=0; f.ui:sync()
    assert(f.modes[1].pc==f.second and f.modes[1].widget==f.h.guest.W_PlayerInventory_Main)
    assert(f.first.bShowMouseCursor and f.second.bShowMouseCursor)
end)
test('closing inventory returns input and cursors to their pre-menu state',function()
    local f=fixture(); f.ui:bind(); f.h.guest.W_PlayerInventory_Main.visibility=0; f.ui:sync()
    f.h.guest.W_PlayerInventory_Main.visibility=1; f.ui:sync()
    assert(f.modes[#f.modes].widget==nil and f.modes[#f.modes].pc==f.second)
    assert(not f.first.bShowMouseCursor and not f.second.bShowMouseCursor)
end)
test('handoff from open guest menu to host gameplay releases old UI focus',function()
    local f=fixture(); f.ui:bind(); f.h.guest.W_PlayerInventory_Main.visibility=0; f.ui:sync()
    f.guest=false; f.ui:sync()
    assert(f.modes[#f.modes].pc==f.first and f.modes[#f.modes].widget==nil)
end)
test('Tab focus does not toggle or close a newly opened native inventory',function()
    local f=fixture(); f.ui:bind(); f.ui:key('tab'); f.h.guest.W_PlayerInventory_Main.visibility=0; f.timers[1]()
    assert(f.closes==0 and f.modes[1].widget==f.h.guest.W_PlayerInventory_Main)
end)
test('Esc closes only the still-open guest through its character and releases focus after settling',function()
    local f=fixture(); f.ui:bind(); f.h.guest.W_PlayerInventory_Main.visibility=0; f.ui:sync()
    f.ui:key('escape'); f.timers[1]()
    assert(f.closes==1 and f.h.main.W_PlayerInventory_Main:GetVisibility()==1)
    f.timers[2]()
    assert(f.modes[#f.modes].widget==nil)
end)
test('native Esc closure prevents duplicate close invocation',function()
    local f=fixture(); f.ui:bind(); f.h.guest.W_PlayerInventory_Main.visibility=0
    f.ui:key('escape'); f.h.guest.W_PlayerInventory_Main.visibility=1; f.timers[1]()
    assert(f.closes==0)
end)
test('restoration cancels delayed UI work and restores only owned references',function()
    local f=fixture(); f.ui:bind(); f.ui:key('tab'); f.ui:restore(); f.timers[1]()
    assert(#f.modes==0 and f.closes==0)
    assert(f.h.guest.W_PlayerInventory_Main.OwningCharacter==f.first.Pawn)
end)
test('an open Escape menu keeps focus and cursor after inventory closes',function()
    local f=fixture(); f.ui:bind(); f.h.guest.W_PlayerInventory_Main.visibility=0; f.ui:sync()
    f.h.guest.W_PlayerInventory_Main.visibility=1; f.h.guest.W_EscapeMenu_Main.visibility=0; f.ui:sync()
    assert(f.modes[#f.modes].widget==f.h.guest.W_EscapeMenu_Main and f.second.bShowMouseCursor)
end)
test('cursor baseline is captured before native menu opening changes its flags',function()
    local f=fixture(); f.ui:bind(); f.second.bShowMouseCursor=true
    f.h.guest.W_PlayerInventory_Main.visibility=0; f.ui:sync()
    f.h.guest.W_PlayerInventory_Main.visibility=1; f.ui:sync()
    assert(not f.first.bShowMouseCursor and not f.second.bShowMouseCursor)
end)
test('returning input to host cancels delayed guest close work',function()
    local f=fixture(); f.ui:bind(); f.h.guest.W_PlayerInventory_Main.visibility=0
    f.ui:key('escape'); f.guest=false; f.timers[1]()
    assert(f.closes==0 and #f.modes==0)
end)
test('unexpected native focus signature is rejected without changing cursor flags',function()
    local f=fixture(); f.ui:bind(); f.h.guest.W_PlayerInventory_Main.visibility=0
    local normal=f.ui.api.find; local bad=object()
    function bad:ForEachProperty(cb)
        local p={}; function p:GetFName() return {ToString=function() return 'Unexpected' end} end
        cb(p)
    end
    f.ui.api.find=function(path) if path:find('SetInputMode_GameAndUIEx',1,true) then return bad end; return normal(path) end
    assert(not pcall(function() f.ui:sync() end))
    assert(f.ui.focus==nil and not f.first.bShowMouseCursor and not f.second.bShowMouseCursor)
end)
test('hidden ancestor prevents focus on a non-displayed inventory',function()
    local f=fixture(); f.ui:bind(); local parent=object(); parent.visibility=1
    f.h.guest.W_PlayerInventory_Main.visibility=0
    function f.h.guest.W_PlayerInventory_Main:GetParent() return parent end
    f.ui:sync(); assert(#f.modes==0 and f.ui.focus==nil)
end)
test('fully faded inventory does not capture input',function()
    local f=fixture(); f.ui:bind(); f.h.guest.W_PlayerInventory_Main.visibility=0
    function f.h.guest.W_PlayerInventory_Main:GetRenderOpacity() return 0 end
    f.ui:sync(); assert(#f.modes==0)
end)
test('inactive widget-switcher child is treated as closed',function()
    local f=fixture(); f.ui:bind(); f.h.guest.W_PlayerInventory_Main.visibility=0
    local parent=object(); parent.visibility=0
    function parent:IsA(kind) return kind=='/Script/UMG.WidgetSwitcher' end
    function parent:GetActiveWidget() return object() end
    function f.h.guest.W_PlayerInventory_Main:GetParent() return parent end
    f.ui:sync(); assert(#f.modes==0)
end)
test('Tab closes a previously open guest window while preserving an open host window',function()
    local f=fixture(); f.ui:bind()
    f.h.main.W_PlayerInventory_Main.visibility=0; f.h.guest.W_PlayerInventory_Main.visibility=0
    f.ui:sync()
    f.ui:key('tab'); f.timers[1](); f.timers[2]()
    assert(f.closes==1 and f.h.guest.W_PlayerInventory_Main.visibility==1 and f.h.main.W_PlayerInventory_Main.visibility==0)
end)
test('a native Tab opener that runs before the key callback is not immediately closed',function()
    local f=fixture(); f.ui:bind(); f.ui:sync()
    f.h.guest.W_PlayerInventory_Main.visibility=0
    f.ui:key('tab'); f.timers[1]()
    assert(f.closes==0 and f.h.guest.W_PlayerInventory_Main.visibility==0)
    assert(f.modes[#f.modes].widget==f.h.guest.W_PlayerInventory_Main)
end)
test('close-only options preserve an exposed mode without passing a container or crafting targets',function()
    local f=fixture(); f.ui:bind(); local root=f.h.guest.W_PlayerInventory_Main
    local class=root:GetClass(); local original=class.ForEachProperty
    function class:ForEachProperty(cb)
        original(self,cb)
        local p={}
        function p:GetFName() return {ToString=function() return 'InventoryMode' end} end
        function p:GetFullName() return 'EnumProperty Fixture:InventoryMode' end
        cb(p)
    end
    root.InventoryMode=3; root.visibility=0
    f.ui:key('escape'); f.timers[1]()
    assert(f.closes==1 and f.closeMode==3)
end)
test('a replacement inventory reference prevents the close request',function()
    local f=fixture(); f.ui:bind(); f.h.guest.W_PlayerInventory_Main.visibility=0
    f.ui:key('escape'); f.second.Pawn.InventoryReference=object(); f.timers[1]()
    assert(f.closes==0 and #f.timers==1)
end)
test('a changed guest pawn prevents the close request',function()
    local f=fixture(); f.ui:bind(); f.h.guest.W_PlayerInventory_Main.visibility=0
    f.ui:key('escape'); f.second.Pawn=object(); f.timers[1]()
    assert(f.closes==0)
end)
test('an unexpected character argument signature stops before native invocation',function()
    local f=fixture(); f.ui:bind(); f.h.guest.W_PlayerInventory_Main.visibility=0
    function f.closeFunction:ForEachProperty(cb)
        local p={}
        function p:GetFName() return {ToString=function() return 'WrongArgument' end} end
        function p:GetFullName() return 'BoolProperty Fixture:WrongArgument' end
        cb(p)
    end
    f.ui:key('escape'); f.timers[1](); assert(f.closes==0)
end)
test('RPC and delegate flags are refused for the character close handler',function()
    for _,flags in ipairs({0x40,0x100000}) do
        local f=fixture(); f.ui:bind(); f.h.guest.W_PlayerInventory_Main.visibility=0; f.closeFlags=flags
        f.ui:key('escape'); f.timers[1](); assert(f.closes==0)
    end
end)
test('a no-op native close is reported as still displayed without hiding the UI',function()
    local f=fixture(); f.ui:bind(); f.h.guest.W_PlayerInventory_Main.visibility=0; f.closeNoop=true
    f.ui:key('escape'); f.timers[1](); f.timers[2]()
    assert(f.closes==1 and f.h.guest.W_PlayerInventory_Main.visibility==0)
    assert(table.concat(f.logs,'\n'):find('UICLOSE settled; guest displayed=true',1,true))
    assert(#f.timers==2)
end)
test('handoff cancels pending settled-focus work after the native close request',function()
    local f=fixture(); f.ui:bind(); f.h.guest.W_PlayerInventory_Main.visibility=0
    f.ui:key('escape'); f.timers[1](); f.guest=false; f.timers[2]()
    assert(f.closes==1 and #f.modes==0)
end)
print(passed .. ' inventory UI tests passed (mock API; actual game binding/delegates and cursor require validation).')
