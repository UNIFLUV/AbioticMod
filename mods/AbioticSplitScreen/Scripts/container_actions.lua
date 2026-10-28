-- Refresh owned guest UI links and exact host caches after native container setup.
-- Inspect one known, owned container widget; never invoke item/save operations.
local Actions={}
Actions.__index=Actions
local function valid(o) return o~=nil and o:IsValid() end
local function same(a,b) return valid(a) and valid(b) and a:GetAddress()==b:GetAddress() end
function Actions.new(api) return setmetatable({api=api,seen={},changes={}},Actions) end
function Actions:tag(value,first,second,component)
    if not valid(value) then return 'NONE' end
    for _,entry in ipairs({
        {first,'host-controller'},{second,'guest-controller'},
        {first.Pawn,'host-character'},{second.Pawn,'guest-character'},
        {first.Pawn.CharacterInventory,'host-backpack'},{second.Pawn.CharacterInventory,'guest-backpack'},
        {component,'opened-container'},
    }) do
        if same(value,entry[1]) then return entry[2] end
    end
    return 'other:'..value:GetClass():GetFName():ToString()
end
function Actions:inspect(widget,first,second,component)
    local class=widget:GetClass()
    local kind=class:GetFName():ToString()
    self.api.log('LOOTUI container widget='..kind)
    -- Field values may change on each opening. Log object roles, not save IDs,
    -- item data or arbitrary string values.
    local count=0
    for _=1,3 do
        if not valid(class) then break end
        class:ForEachProperty(function(p)
            if p:GetFullName():match('^ObjectProperty ') then
                count=count+1;if count>48 then return true end
                local key=p:GetFName():ToString()
                local ok,value=pcall(function() return self:tag(widget[key],first,second,component) end)
                self.api.log('LOOTUI REF '..key..' -> '..(ok and value or 'unavailable'))
            end
        end)
        -- Function metadata once per class: Blueprint locals can identify a
        -- hard-coded player lookup, but are never treated as callable arguments.
        local id=class:GetAddress()
        if not self.seen[id] or not same(self.seen[id],class) then
            self.seen[id]=class
            local functions=0
            class:ForEachFunction(function(f)
                local name=f:GetFName():ToString():lower()
                if name:find('take',1,true) or name:find('transfer',1,true) or name:find('loot',1,true) then
                    functions=functions+1;if functions>8 then return true end
                    self.api.log('LOOTUI FUNCTION '..f:GetFullName())
                    local fields=0
                    f:ForEachProperty(function(p)
                        fields=fields+1;if fields>32 then return true end
                        self.api.log('LOOTUI FIELD '..p:GetFullName())
                    end)
                end
            end)
        end
        if count>48 then self.api.log('LOOTUI reference metadata truncated');break end
        class=class:GetSuperStruct()
    end
end
function Actions:repair(component)
    local _,first,second=self.api.pair()
    local h=assert(self.api.huds(),'HUD pair missing')
    assert(valid(first.Pawn) and valid(second.Pawn) and not same(first.Pawn,second.Pawn),'Distinct characters required')
    local root=h.guest.W_PlayerInventory_Main
    assert(valid(root) and same(root:GetOwningPlayer(),second) and same(second.Pawn.InventoryReference,root),
        'Guest inventory ownership changed')
    assert(valid(component) and component:IsA('/Script/Engine.ActorComponent'),'Container component required')
    if not same(root.ActiveContainer,component) then
        self.api.log('LOOTUI waiting for the requested guest container; character links left unchanged')
        return false
    end
    local widget=root.CurrentContainerWidget
    assert(valid(widget) and same(widget:GetOwningPlayer(),second),'Guest container widget has another owner')
    local has_character=self.api.property(widget,'OwningCharacter','ObjectProperty')
    local before=has_character and widget.OwningCharacter or nil
    assert(not valid(before) or same(before,first.Pawn) or same(before,second.Pawn),'Unknown container character reference')
    local ok,message=pcall(function() self:inspect(widget,first,second,component) end)
    if not ok then self.api.log('LOOTUI partial metadata: '..tostring(message)) end
    local updates={}
    for _,key in ipairs({'PlayerInventory','CharacterInventory','MyPlayerController','OwningPlayerController'}) do
        if self.api.property(widget,key,'ObjectProperty') then
            local inventory=key=='PlayerInventory' or key=='CharacterInventory'
            local old=widget[key]
            local source,target
            if inventory then source,target=first.Pawn.CharacterInventory,second.Pawn.CharacterInventory
            else source,target=first,second end
            -- Only an existing exact host-cache reference on this guest widget
            -- authorizes a write. Generic/source container inventory fields,
            -- nil values, and third-party references are never guessed.
            if same(old,source) then
                assert(valid(target) and not same(source,target),'Distinct guest cache target required')
                assert(same(source:GetClass(),target:GetClass()),'Host and guest cache target types differ')
                if inventory then
                    assert(source:IsA('/Script/Engine.ActorComponent') and target:IsA('/Script/Engine.ActorComponent') and
                        same(source:GetOwner(),first.Pawn) and same(target:GetOwner(),second.Pawn),
                        'Backpack component ownership does not match the two characters')
                end
                updates[#updates+1]={widget=widget,pc=second,key=key,old=old,new=target}
            end
        end
    end
    -- Existing inventory_ui.bind validates all its known child owners/field
    -- types before writing. It also owns restoration of these references.
    self.api.bind()
    assert(same(root.ActiveContainer,component),'Container changed while refreshing character links')
    if has_character then assert(same(widget.OwningCharacter,second.Pawn),'Guest container character link not confirmed') end
    local attempted={}
    local applied,why=pcall(function()
        for _,r in ipairs(updates) do
            assert(same(r.widget:GetOwningPlayer(),r.pc) and same(r.widget[r.key],r.old),'Container cache changed during binding')
            attempted[#attempted+1]=r
            r.widget[r.key]=r.new
            assert(same(r.widget[r.key],r.new),'Container cache write not confirmed')
        end
    end)
    if not applied then
        self:restore(attempted)
        error(why)
    end
    for _,r in ipairs(updates) do
        local id=tostring(r.widget:GetAddress())..':'..r.key
        if not self.changes[id] then self.changes[id]=r end
        self.api.log('LOOTUI rebound owned guest container cache: '..r.key)
    end
    self.api.log('LOOTUI refreshed existing guest UI links after native container setup; container character field='..
        tostring(has_character)..'; previous character was host='..tostring(same(before,first.Pawn)))
    return true
end
function Actions:restore(records)
    local failure
    for _,r in pairs(records) do
        local ok,message=pcall(function()
            if valid(r.widget) and same(r.widget:GetOwningPlayer(),r.pc) and same(r.widget[r.key],r.new) then
                r.widget[r.key]=valid(r.old) and r.old or nil
            end
        end)
        if not ok then failure=tostring(message) end
    end
    if failure then error('Container cache restoration failed: '..failure) end
end
function Actions:clear()
    self:restore(self.changes)
    self.seen={};self.changes={}
end
return Actions
