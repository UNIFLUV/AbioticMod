local Ui = {}
Ui.__index = Ui
local function valid(v) return v ~= nil and v:IsValid() end
local function same(a,b) return valid(a) and valid(b) and a:GetAddress() == b:GetAddress() end
local function visible(w)
    if not valid(w) then return false end
    local seen = {}
    for _ = 1,24 do
        local id = w:GetAddress()
        if seen[id] then return false end
        seen[id] = true
        local v = w:GetVisibility()
        if v ~= 0 and v ~= 3 and v ~= 4 then return false end
        local ok,opacity = pcall(function() return w:GetRenderOpacity() end)
        if ok and type(opacity)=='number' and opacity<=0.01 then return false end
        local parent_ok,parent = pcall(function() return w:GetParent() end)
        if parent_ok and valid(parent) then
            local active_ok,active = pcall(function()
                if parent:IsA('/Script/UMG.WidgetSwitcher') then return parent:GetActiveWidget() end
            end)
            if active_ok and valid(active) and not same(active,w) then return false end
            w = parent
        else
            local outer_ok,owner = pcall(function()
                local tree = w:GetOuter()
                if valid(tree) and tree:IsA('/Script/UMG.WidgetTree') then return tree:GetOuter() end
            end)
            if not outer_ok or not valid(owner) then return true end
            w = owner
        end
    end
    return false
end
local function property(o, key, kind)
    kind = kind or 'ObjectProperty'
    local c = o:GetClass()
    for _ = 1,4 do
        if not valid(c) then break end
        local found = false
        c:ForEachProperty(function(p)
            if p:GetFName():ToString() == key and p:GetFullName():match('^'..kind..' ') then found = true end
        end)
        if found then return true end
        c = c:GetSuperStruct()
    end
    return false
end
function Ui.new(api) return setmetatable({api=api, refs={}, generation=0}, Ui) end
function Ui:bind()
    local _, first, second = self.api.pair()
    assert(valid(first.Pawn) and valid(second.Pawn) and not same(first.Pawn,second.Pawn), 'Two separate pawns required')
    local h = assert(self.api.huds(), 'HUD pair missing')
    local root = h.guest.W_PlayerInventory_Main
    assert(valid(root) and same(root:GetOwningPlayer(),second), 'Inventory owner changed')
    if self.pawn then assert(same(self.pawn,second.Pawn), 'Restart after a pawn change') end
    local widgets = {root}
    for _, key in ipairs({'W_Inventory_PlayerBackpack','W_Inventory_EquipSlots','InventoryHealthPanel','W_Inventory_CraftingArea','W_PlayerHUD_Hotbar','W_InventoryGenericDropArea','CurrentContainerWidget'}) do
        local w = root[key]
        if valid(w) then widgets[#widgets+1]=w end
    end
    local updates = {}
    for _, w in ipairs(widgets) do
        assert(same(w:GetOwningPlayer(),second), 'Child inventory widget has another controller')
        if property(w,'OwningCharacter') then
            local old = w.OwningCharacter
            assert(not valid(old) or same(old,first.Pawn) or same(old,second.Pawn), 'Unknown UI character reference')
            updates[#updates+1]={widget=w, old=valid(old) and old or nil}
        end
    end
    assert(property(root,'OwningCharacter'), 'Inventory character field missing')
    if not self.cursors and type(first.bShowMouseCursor)=='boolean' and type(second.bShowMouseCursor)=='boolean' then
        self.cursors={{pc=first,old=first.bShowMouseCursor},{pc=second,old=second.bShowMouseCursor}}
    end
    self.pawn = second.Pawn
    for _, r in ipairs(updates) do
        local id = r.widget:GetAddress()
        if not self.refs[id] then self.refs[id]=r end
        r.widget.OwningCharacter=second.Pawn
        assert(same(r.widget.OwningCharacter,second.Pawn), 'UI character write not confirmed')
    end
    self.api.log('UIOWNER guest inventory and owned child character references verified')
end
function Ui:mode(pc, widget)
    local method = widget and 'SetInputMode_GameAndUIEx' or 'SetInputMode_GameOnly'
    local func = self.api.find('/Script/UMG.WidgetBlueprintLibrary:' .. method)
    local library = self.api.find('/Script/UMG.Default__WidgetBlueprintLibrary')
    assert(valid(func) and valid(library), 'Input-mode API missing')
    local expected = widget and {'PlayerController','InWidgetToFocus','InMouseLockMode','bHideCursorDuringCapture','bFlushInput'} or {'PlayerController','bFlushInput'}
    local args = widget and {pc,widget,0,false,false} or {pc,false}
    local count = 0
    func:ForEachProperty(function(p)
        count=count+1
        assert(p:GetFName():ToString()==expected[count], 'Unexpected input-mode signature')
    end)
    assert(count==#expected or count==#expected-1, 'Input-mode argument count mismatch')
    func(library,table.unpack(args,1,count))
end
function Ui:release()
    local r = self.focus
    if not r then return end
    for _, saved in ipairs(r.cursors) do
        if valid(saved.pc) and saved.pc.bShowMouseCursor==true then saved.pc.bShowMouseCursor=saved.old end
    end
    self.focus=nil
end
function Ui:sync()
    local _, first, second = self.api.pair()
    local h = self.api.huds()
    if not h then return end
    local guest = self.api.guest_active()
    local pc, hud = guest and second or first, guest and h.guest or h.main
    local inv, esc = hud.W_PlayerInventory_Main, hud.W_EscapeMenu_Main
    self.observed_inventory = visible(inv) and visible(inv.InventoryMain) and inv or nil
    local target = visible(esc) and esc or self.observed_inventory
    local had_focus = self.focus~=nil
    if self.focus and not same(self.focus.pc,pc) then self:release() end
    if target then
        if not self.focus then
            assert(type(first.bShowMouseCursor)=='boolean' and type(second.bShowMouseCursor)=='boolean', 'Cursor flags unavailable')
            self.focus={pc=pc,cursors=self.cursors or {{pc=first,old=false},{pc=second,old=false}}}
        end
        local ok,message=pcall(function() self:mode(pc,target) end)
        if not ok then self:release(); error(message) end
        -- The viewport hardware cursor can consult its first local controller.
        first.bShowMouseCursor=true
        second.bShowMouseCursor=true
        self.api.log('UIFOCUS active local player focused; viewport cursor shown')
    elseif had_focus then
        self:mode(pc,nil)
        self:release()
        self.api.log('UIFOCUS game input restored after menu closure')
    end
end
function Ui:close_inventory(pc, root)
    local _, first, second = self.api.pair()
    assert(same(pc,second) and same(second.Pawn,self.pawn), 'Guest character changed')
    assert(same(root,self.api.huds().guest.W_PlayerInventory_Main) and
        same(root:GetOwningPlayer(),second) and same(root.OwningCharacter,second.Pawn) and
        same(second.Pawn.InventoryReference,root), 'Guest inventory ownership changed')
    local func=self.api.find('/Game/Blueprints/Characters/Abiotic_PlayerCharacter.Abiotic_PlayerCharacter_C:ToggleInventory')
    assert(valid(func), 'Character inventory close handler missing')
    local expected={
        {'ForceClose','BoolProperty'}, {'InventoryMode','EnumProperty'},
        {'CraftingBenchesAvailable','ArrayProperty'}, {'ContainerInventoryComponent','ObjectProperty'},
        {'CustomUIKeyboardFocus','BoolProperty'},
    }
    local count=0
    func:ForEachProperty(function(p)
        local key=p:GetFName():ToString()
        if count<#expected then
            count=count+1
            assert(key==expected[count][1] and p:GetFullName():match('^'..expected[count][2]..' '),
                'Unexpected character inventory close signature: '..p:GetFullName())
        else
            assert(key:match('^CallFunc_') or key:match('^K2Node_') or key:match('^Temp_'),
                'Character inventory close has an unknown argument: '..p:GetFullName())
        end
    end)
    assert(count==#expected, 'Incomplete character inventory close signature')
    local flags=func:GetFunctionFlags()
    assert(type(flags)=='number' and (flags & 0x40)==0 and (flags & 0x100000)==0,
        'Expected a local character function, not an RPC or delegate')
    -- This is a close-only request. Do not supply a new container or crafting
    -- targets. Preserve the widget mode when it exposes a confirmed enum field;
    -- otherwise zero-initialize the open-only mode option, with ForceClose=true.
    local mode,source=0,'zero-initialized close option'
    for _,key in ipairs({'InventoryMode','CurrentInventoryMode'}) do
        if property(root,key,'EnumProperty') then
            mode=root[key]; source=key
            assert(type(mode)=='number' and mode%1==0 and mode>=0 and mode<=255, 'Invalid inventory mode')
            break
        end
    end
    local host=self.api.huds().main.W_PlayerInventory_Main
    self.api.log('UICLOSE requesting guest Pawn.ToggleInventory ForceClose=true; mode='..mode..' ('..source..'); host displayed='..
        tostring(visible(host) and visible(host.InventoryMain)))
    func(second.Pawn,true,mode,{},nil,false)
    self.api.log('UICLOSE character handler returned; guest displayed='..tostring(visible(root) and visible(root.InventoryMain)))
end
function Ui:key(kind)
    if not self.api.guest_active() then return end
    local _, _, second = self.api.pair()
    local root = self.api.huds().guest.W_PlayerInventory_Main
    -- A native Tab opener may run before this game-thread callback. Only treat
    -- Tab as a close intent if the inventory was observed open on the prior sync.
    local close = visible(root) and visible(root.InventoryMain) and
        (kind=='escape' or (kind=='tab' and same(self.observed_inventory,root)))
    self.generation=self.generation+1
    local ticket=self.generation
    self.api.delay(120,function()
        self.api.game_thread(function()
            if ticket~=self.generation or not self.api.guest_active() then return end
            local ok,message=pcall(function()
                local _,_,current=self.api.pair()
                assert(same(second,current), 'Input controller changed')
                if close and visible(root) and visible(root.InventoryMain) then
                    self:close_inventory(second,root)
                    -- Allow the native close animation/state transition to settle
                    -- before choosing keyboard focus again. One shot, no polling.
                    self.api.delay(250,function()
                        self.api.game_thread(function()
                            if ticket~=self.generation or not self.api.guest_active() then return end
                            local settled,message=pcall(function()
                                local _,_,active=self.api.pair()
                                assert(same(second,active) and same(active.Pawn,self.pawn) and
                                    same(root,self.api.huds().guest.W_PlayerInventory_Main), 'Close context changed')
                                local displayed=visible(root) and visible(root.InventoryMain)
                                self.api.log('UICLOSE settled; guest displayed='..tostring(displayed))
                                self:sync()
                            end)
                            if not settled then self.api.log('UICLOSE completion stopped: '..tostring(message)) end
                        end)
                    end)
                    return
                end
                self:sync()
            end)
            if not ok then self.api.log('UIFOCUS stopped: ' .. tostring(message)) end
        end)
    end)
end
function Ui:restore()
    self.generation=self.generation+1
    if self.focus then
        local ok=pcall(function()
            local _,first,second=self.api.pair()
            if same(self.focus.pc,first) or same(self.focus.pc,second) then self:mode(self.focus.pc,nil) end
        end)
        if not ok then self.api.log('UIFOCUS teardown could not restore input mode') end
        self:release()
    end
    for _,r in pairs(self.refs) do
        if valid(r.widget) and same(r.widget.OwningCharacter,self.pawn) then r.widget.OwningCharacter=valid(r.old) and r.old or nil end
    end
    self.refs={}
    self.pawn=nil
    self.cursors=nil
    self.observed_inventory=nil
end
return Ui
