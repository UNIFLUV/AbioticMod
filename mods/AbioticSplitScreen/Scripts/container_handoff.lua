-- Keyboard-only repair of a container window opened on the wrong local HUD.
-- No RegisterHook, shared actor rewrites, save changes, or guessed nearby targets.
local Bridge={}
Bridge.__index=Bridge
local function valid(o) return o~=nil and o:IsValid() end
local function same(a,b) return valid(a) and valid(b) and a:GetAddress()==b:GetAddress() end
function Bridge.new(api) return setmetatable({api=api,generation=0},Bridge) end
function Bridge:cancel() self.generation=self.generation+1 end
function Bridge:pair()
    local context,first,second=self.api.pair()
    local h=assert(self.api.huds(),'HUD pair missing')
    assert(valid(context.world) and valid(first.Pawn) and valid(second.Pawn) and
        not same(first,second) and not same(first.Pawn,second.Pawn),'Distinct local characters required')
    local host,guest=h.main.W_PlayerInventory_Main,h.guest.W_PlayerInventory_Main
    assert(valid(host) and valid(guest) and not same(host,guest),'Separate inventory widgets required')
    for i,root in ipairs({host,guest}) do
        local pc=i==1 and first or second
        assert(valid(root) and valid(root.InventoryMain) and same(root:GetOwningPlayer(),pc) and
            same(root.OwningCharacter,pc.Pawn) and same(pc.Pawn.InventoryReference,root),'Container UI ownership changed')
    end
    return context,first,second,host,guest
end
function Bridge:displayed(root)
    return valid(root) and self.api.visible(root) and self.api.visible(root.InventoryMain)
end
function Bridge:escape_open()
    local h=assert(self.api.huds(),'HUD pair missing')
    return self.api.visible(h.main.W_EscapeMenu_Main) or self.api.visible(h.guest.W_EscapeMenu_Main)
end
function Bridge:remember()
    local context,first,second,host,guest=self:pair()
    self.observed={world=context.world,first=first,second=second,host=host,guest=guest,
        host_pawn=first.Pawn,guest_pawn=second.Pawn,displayed=self:displayed(host)}
end
function Bridge:matches(record)
    local context,first,second,host,guest=self:pair()
    assert(same(context.world,record.world) and same(first,record.first) and same(second,record.second) and
        same(first.Pawn,record.host_pawn) and same(second.Pawn,record.guest_pawn) and
        same(host,record.host) and same(guest,record.guest),'Container interaction context changed')
end
function Bridge:handler()
    local f=self.api.find('/Game/Blueprints/Characters/Abiotic_PlayerCharacter.Abiotic_PlayerCharacter_C:ToggleInventory')
    assert(valid(f),'Character inventory handler missing')
    local fields={{'ForceClose','BoolProperty'},{'InventoryMode','EnumProperty'},
        {'CraftingBenchesAvailable','ArrayProperty'},{'ContainerInventoryComponent','ObjectProperty'},
        {'CustomUIKeyboardFocus','BoolProperty'}}
    local n=0
    f:ForEachProperty(function(p)
        local key=p:GetFName():ToString()
        if n<#fields then
            n=n+1
            assert(key==fields[n][1] and p:GetFullName():match('^'..fields[n][2]..' '),'Unexpected container handler signature')
        else
            assert(key:match('^CallFunc_') or key:match('^K2Node_') or key:match('^Temp_'),'Unknown container handler argument')
        end
    end)
    local flags=f:GetFunctionFlags()
    assert(n==#fields and type(flags)=='number' and (flags & 0x40)==0 and (flags & 0x100000)==0,
        'Expected local inventory handler, not RPC or delegate')
    return f
end
function Bridge:restore_host(r)
    self:matches(r)
    assert(valid(r.component),'Container component expired')
    -- Do not replace an independently opened guest window or another host menu.
    if self:displayed(r.guest) or self:displayed(r.host) then return false end
    r.handler(r.host_pawn,false,r.mode,{},r.component,false)
    self.api.log('CONTAINER host restore requested after unsuccessful handoff')
    return true
end
function Bridge:key()
    if not self.api.guest_active() then return end
    local context,first,second,host,guest=self:pair()
    if self:escape_open() then return end
    local before=self.observed
    local r={world=context.world,first=first,second=second,host=host,guest=guest,
        host_pawn=first.Pawn,guest_pawn=second.Pawn,target=second.Pawn.BestInteractable_InteractA}
    self:cancel(); local ticket=self.generation
    self.api.delay(220,function()
        self.api.game_thread(function()
            if ticket~=self.generation or not self.api.guest_active() then return end
            local ok,message=pcall(function()
                self:matches(r)
                if self:escape_open() then return end
                if not self:displayed(host) or self:displayed(guest) then self.api.sync(); return end
                assert(before and same(before.world,r.world) and same(before.first,first) and same(before.second,second) and
                    same(before.host_pawn,r.host_pawn) and same(before.guest_pawn,r.guest_pawn) and
                    same(before.host,host) and same(before.guest,guest) and before.displayed==false,
                    'Host menu was already open or its prior state is unknown')
                assert(valid(r.target),'Guest target unavailable; no container was transferred')
                r.component=host.ActiveContainer
                assert(valid(r.component) and r.component:IsA('/Script/Engine.ActorComponent'),'Opened window has no container component')
                assert(same(r.component,r.target) or same(r.component:GetOwner(),r.target),
                    'Host container differs from the guest interaction target')
                assert(self.api.property(host,'InventoryMode','EnumProperty'),'Container mode enum missing')
                r.mode=host.InventoryMode
                assert(type(r.mode)=='number' and r.mode%1==0 and r.mode>=0 and r.mode<=255,'Invalid container mode')
                r.handler=self:handler() -- Finish validation before closing either window.
                r.closed=true
                r.handler(r.host_pawn,true,r.mode,{},nil,false)
                assert(not self:displayed(host),'Host window has not closed; guest open skipped')
                self:matches(r)
                assert(valid(r.component) and (same(r.component,r.target) or same(r.component:GetOwner(),r.target)),
                    'Container component changed during close')
                r.handler(r.guest_pawn,false,r.mode,{},r.component,false)
                self.api.log('CONTAINER matching guest open requested; awaiting actual UI result')
                self.api.delay(250,function()
                    self.api.game_thread(function()
                        if ticket~=self.generation or not self.api.guest_active() then return end
                        local settled,why=pcall(function()
                            self:matches(r)
                            local success=self:displayed(guest) and same(guest.ActiveContainer,r.component) and not self:displayed(host)
                            self.api.log('CONTAINER settled; guest displayed='..tostring(self:displayed(guest))..
                                '; matching component='..tostring(same(guest.ActiveContainer,r.component))..
                                '; host displayed='..tostring(self:displayed(host)))
                            if not success then self:restore_host(r) end
                            self.api.sync()
                        end)
                        if not settled then self.api.log('CONTAINER completion stopped: '..tostring(why)) end
                    end)
                end)
            end)
            if not ok then
                self.api.log('CONTAINER unchanged or handoff stopped: '..tostring(message))
                if r.closed then
                    local restored,why=pcall(function() self:restore_host(r); self.api.sync() end)
                    if not restored then self.api.log('CONTAINER restore stopped: '..tostring(why)) end
                else
                    local focused,why=pcall(self.api.sync)
                    if not focused then self.api.log('CONTAINER focus check stopped: '..tostring(why)) end
                end
            end
        end)
    end)
end
function Bridge:clear() self:cancel(); self.observed=nil end
return Bridge
