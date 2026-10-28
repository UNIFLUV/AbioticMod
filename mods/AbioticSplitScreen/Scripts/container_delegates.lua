-- Retarget proven foreign event receivers on known guest inventory widgets.
-- Uses UE4SS 1ba38db4's delegate API, not RegisterHook or item function calls.
local Events={}
Events.__index=Events
local kinds={DelegateProperty=true,MulticastDelegateProperty=true,
    MulticastInlineDelegateProperty=true,MulticastSparseDelegateProperty=true}
local function valid(o) return o~=nil and o:IsValid() end
local function same(a,b) return valid(a) and valid(b) and a:GetAddress()==b:GetAddress() end
local function name(b) return b.FunctionName:ToString() end
local function key(b) return tostring(b.Object:GetAddress())..':'..name(b) end
local function equal(a,b)
    if #a~=#b then return false end
    local counts={}
    for _,v in ipairs(a) do local k=key(v);counts[k]=(counts[k] or 0)+1 end
    for _,v in ipairs(b) do local k=key(v);counts[k]=(counts[k] or 0)-1 end
    for _,n in pairs(counts) do if n~=0 then return false end end
    return true
end
local function has(list,b)
    for _,v in ipairs(list) do if same(v.Object,b.Object) and name(v)==name(b) then return true end end
    return false
end
local function owned(o,pc)
    for _=1,12 do
        if not valid(o) then return false end
        if o:IsA('/Script/UMG.UserWidget') then return same(o:GetOwningPlayer(),pc) end
        o=o:GetOuter()
    end
    return false
end
local function handler(o,fn)
    local c=o:GetClass()
    for _=1,4 do
        if not valid(c) then break end
        local found
        c:ForEachFunction(function(f)
            if f:GetFName():ToString()==fn then found=f;return true end
        end)
        if found then return found end
        c=c:GetSuperStruct()
    end
end
function Events.new(api) return setmetatable({api=api,records={}},Events) end
function Events:read(r)
    local value=r.widget[r.field]
    local list
    if r.kind=='DelegateProperty' then
        assert(type(value)=='table','Single delegate API unavailable')
        list=valid(value.Object) and {value} or {}
    else
        assert(value~=nil and type(value.GetBindings)=='function' and type(value.Add)=='function' and
            type(value.Remove)=='function','UE4SS delegate GetBindings/Add/Remove unavailable')
        list=value:GetBindings() or {}
    end
    assert(type(list)=='table' and #list<=64,'Unexpected delegate binding list')
    local seen={}
    for _,b in ipairs(list) do
        assert(valid(b.Object) and type(name(b))=='string' and name(b)~='None','Invalid delegate receiver')
        assert(not seen[key(b)],'Duplicate binding list is preserved');seen[key(b)]=true
    end
    return list
end
function Events:write(r,current,wanted)
    for _,b in ipairs(wanted) do assert(valid(b.Object),'Saved delegate receiver expired') end
    if r.kind=='DelegateProperty' then
        r.widget[r.field]=wanted[1]
    else
        local delegate=r.widget[r.field]
        for _,b in ipairs(current) do
            if not has(wanted,b) then
                local next_list={}
                for _,v in ipairs(current) do if key(v)~=key(b) then next_list[#next_list+1]=v end end
                r.states[#r.states+1]=next_list
                delegate:Remove(b.Object,b.FunctionName)
                assert(equal(self:read(r),next_list),'Delegate Remove result differs')
                current=next_list
            end
        end
        for _,b in ipairs(wanted) do
            if not has(current,b) then
                local next_list={table.unpack(current)};next_list[#next_list+1]=b
                r.states[#r.states+1]=next_list
                delegate:Add(b.Object,b.FunctionName)
                assert(equal(self:read(r),next_list),'Delegate Add result differs')
                current=next_list
            end
        end
    end
    assert(equal(self:read(r),wanted),'Delegate binding write not confirmed')
end
function Events:restore(records)
    local failure
    for _,r in pairs(records) do
        local ok,message=pcall(function()
            if not valid(r.widget) or not owned(r.widget,r.pc) then return end
            local current=self:read(r)
            local known=equal(current,r.after)
            for _,state in ipairs(r.states) do if equal(current,state) then known=true end end
            if known then
                self:write(r,current,r.before)
            else self.api.log('LOOTBIND external binding change preserved: '..r.label..'.'..r.field) end
        end)
        if not ok then failure=tostring(message) end
    end
    if failure then error('Delegate restoration failed: '..failure) end
end
function Events:repair(component)
    local _,first,second=self.api.pair()
    local h=assert(self.api.huds(),'HUD pair missing')
    local host,guest=h.main.W_PlayerInventory_Main,h.guest.W_PlayerInventory_Main
    assert(valid(component) and component:IsA('/Script/Engine.ActorComponent'),'Container component required')
    assert(valid(first.Pawn) and valid(second.Pawn) and not same(first.Pawn,second.Pawn),'Distinct characters required')
    assert(owned(host,first) and owned(guest,second) and same(second.Pawn.InventoryReference,guest) and
        same(guest.ActiveContainer,component),'Guest container ownership/component changed')
    self.api.bind() -- Retain the existing validated character links.
    local map,scopes,scoped={},{},{}
    local function pair(a,b,label,widgets)
        if not valid(a) or not valid(b) or same(a,b) or not same(a:GetClass(),b:GetClass()) then return end
        if widgets and (not owned(a,first) or not owned(b,second)) then return end
        map[a:GetAddress()]={source=a,target=b,label=label}
    end
    local function scope(o,label)
        if valid(o) and not scoped[o:GetAddress()] then
            if owned(o,second) then
                scoped[o:GetAddress()]=true;scopes[#scopes+1]={widget=o,label=label}
            else self.api.log('LOOTBIND foreign widget preserved: '..label) end
        end
    end
    pair(first,second,'controller',false);pair(first.Pawn,second.Pawn,'character',false)
    pair(h.main,h.guest,'HUD',true);pair(host,guest,'inventory',true)
    scope(guest,'inventory')
    for _,field in ipairs({'W_Inventory_PlayerBackpack','CurrentContainerWidget'}) do
        pair(host[field],guest[field],field,true);scope(guest[field],field)
    end
    local old_container,container=host.CurrentContainerWidget,guest.CurrentContainerWidget
    assert(valid(container) and owned(container,second),'Guest container widget owner changed')
    for _,field in ipairs({'W_InventoryGrid','Button_TakeAll','Keybind_TakeAll','Keybind_TakeAll_1','Keybind_TakeAll_3'}) do
        if valid(old_container) then pair(old_container[field],container[field],field,true) end
        scope(container[field],field)
    end
    local plans,events,bindings={},0,0
    for _,entry in ipairs(scopes) do
        local c,seen,count=entry.widget:GetClass(),{},0
        for _=1,3 do
            if not valid(c) then break end
            c:ForEachProperty(function(p)
                local kind=p:GetFullName():match('^(%w+) ')
                local field=p:GetFName():ToString()
                if kinds[kind] and not seen[field] then
                    seen[field]=true;count=count+1;assert(count<=32,'Too many widget events')
                    events=events+1
                    local r={widget=entry.widget,pc=second,label=entry.label,field=field,kind=kind,states={}}
                    local ok,message=pcall(function()
                        r.before=self:read(r);r.after={}
                        local id=tostring(r.widget:GetAddress())..':'..field
                        local prior=self.records[id]
                        if prior and not equal(r.before,prior.before) and not equal(r.before,prior.after) then
                            self.api.log('LOOTBIND changed event preserved: '..entry.label..'.'..field);return
                        end
                        local replacement={}
                        for _,b in ipairs(r.before) do
                            bindings=bindings+1
                            local m=map[b.Object:GetAddress()]
                            self.api.log('LOOTBIND '..entry.label..'.'..field..' receiver='..
                                (m and ('host-'..m.label) or (owned(b.Object,second) and 'guest-widget' or 'other'))..' function='..name(b))
                            if m and same(m.source,b.Object) then
                                local f=handler(m.target,name(b))
                                assert(valid(f),'Corresponding guest event handler missing')
                                local flags=f:GetFunctionFlags()
                                assert(type(flags)=='number' and (flags & 0x40)==0 and (flags & 0x100000)==0,
                                    'RPC/delegate receiver is not redirected')
                                replacement[#replacement+1]={Object=m.target,FunctionName=b.FunctionName}
                            else r.after[#r.after+1]=b end
                        end
                        for _,b in ipairs(replacement) do if not has(r.after,b) then r.after[#r.after+1]=b end end
                        if not equal(r.before,r.after) then
                            assert(#plans<128,'Too many event rewrites')
                            r.id=id;r.states={r.before,r.after};plans[#plans+1]=r
                        end
                    end)
                    if not ok then self.api.log('LOOTBIND event preserved: '..entry.label..'.'..field..': '..tostring(message)) end
                end
            end)
            c=c:GetSuperStruct()
        end
    end
    local attempted={}
    local ok,message=pcall(function()
        for _,r in ipairs(plans) do
            assert(owned(r.widget,second) and same(guest.ActiveContainer,component),'Event context changed')
            local current=self:read(r);assert(equal(current,r.before),'Event bindings changed during repair')
            attempted[#attempted+1]=r;self:write(r,current,r.after)
        end
    end)
    if not ok then self:restore(attempted);error(message) end
    for _,r in ipairs(plans) do
        -- Intermediate states authorize rollback of a failed transaction only.
        -- Committed teardown must not mistake an external Clear for our Remove.
        r.states={}
        if not self.records[r.id] then self.records[r.id]=r end
        self.api.log('LOOTBIND retargeted owned guest event: '..r.label..'.'..r.field)
    end
    self.api.log('LOOTBIND inspected events='..events..'; bindings='..bindings..'; changed='..#plans..
        '; native Take All destination still requires validation')
end
function Events:clear()
    self:restore(self.records);self.records={}
end
return Events
