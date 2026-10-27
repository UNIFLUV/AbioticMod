-- Repair only player-owned marker UI, never its linked world actor or quest data.
local Markers = {}
Markers.__index = Markers
local function valid(v) return v~=nil and v:IsValid() end
local function same(a,b) return valid(a) and valid(b) and a:GetAddress()==b:GetAddress() end
local function belongs(widget, root)
    local queue,seen={widget},{}
    for i=1,32 do
        local o=queue[i]
        if not o then break end
        if valid(o) and not seen[o:GetAddress()] then
            if same(o,root) then return true end
            seen[o:GetAddress()]=true
            for _,method in ipairs({'GetParent','GetOuter'}) do
                local ok,p=pcall(function() return o[method](o) end)
                if ok and valid(p) then queue[#queue+1]=p end
            end
        end
    end
    return false
end
function Markers.new(api) return setmetatable({api=api,changes={},seen={}},Markers) end
function Markers:remember(w,key,old,new)
    local id=tostring(w:GetAddress())..':'..key
    if not self.seen[id] then self.seen[id]=true; self.changes[#self.changes+1]={w=w,key=key,old=old,new=new} end
end
function Markers:repair()
    local _,first,second=self.api.pair()
    local h=self.api.huds()
    if not h or not valid(h.guest) then return end
    local count=0
    for _,w in ipairs(self.api.find_all('UserWidget') or {}) do
        if valid(w) then
            local kind=w:GetClass():GetFName():ToString():lower()
            if (kind:find('waypoint',1,true) or kind:find('marker',1,true) or kind:find('questobjective',1,true)) and belongs(w,h.guest) then
                count=count+1
                if count>32 then self.api.log('WAYPOINT scan truncated'); break end
                local ok,message=pcall(function()
                    local owner=w:GetOwningPlayer()
                    self.api.log('WAYPOINT guest widget '..w:GetFullName()..'; owner matches guest='..tostring(same(owner,second)))
                    if not valid(owner) or same(owner,first) then
                        self:remember(w,'@owner',valid(owner) and owner or nil,second)
                        w:SetOwningPlayer(second)
                        assert(same(w:GetOwningPlayer(),second),'Marker owner write not confirmed')
                    else assert(same(owner,second),'Unknown marker owner') end
                    local class=w:GetClass()
                    for _=1,4 do
                        if not valid(class) then break end
                        class:ForEachProperty(function(p)
                            local key=p:GetFName():ToString()
                            local text=p:GetFullName()
                            if text:match('^ObjectProperty ') and (key:lower():find('controller',1,true) or key=='OwningCharacter' or key=='LinkedActor') then
                                local value=w[key]
                                self.api.log('WAYPOINT REF '..key..' -> '..(valid(value) and value:GetFullName() or 'NONE'))
                            end
                            local pc=key=='MyPlayerController' or key=='OwningPlayerController' or key=='CachedPlayerController' or key=='LocalPlayerController' or key=='OwningController'
                            local pawn=key=='OwningCharacter' or key=='MyPlayerCharacter'
                            if text:match('^ObjectProperty ') and (pc or pawn) then
                                local old=w[key]; local source=pc and first or first.Pawn; local target=pc and second or second.Pawn
                                if not valid(old) or same(old,source) then
                                    self:remember(w,key,valid(old) and old or nil,target); w[key]=target
                                    assert(same(w[key],target),'Marker reference write not confirmed')
                                    self.api.log('WAYPOINT repaired '..key)
                                end
                            elseif text:match('^BoolProperty ') and (key=='bPlayerViewportRelative' or key=='PlayerViewportRelative') and w[key]==false then
                                self:remember(w,key,false,true); w[key]=true
                                self.api.log('WAYPOINT enabled player viewport coordinates')
                            end
                        end)
                        class=class:GetSuperStruct()
                    end
                end)
                if not ok then self.api.log('WAYPOINT skipped: '..tostring(message)) end
            end
        end
    end
    self.api.log('WAYPOINT guest widgets inspected='..count)
end
function Markers:restore()
    for i=#self.changes,1,-1 do
        local r=self.changes[i]
        if valid(r.w) then
            if r.key=='@owner' then
                if same(r.w:GetOwningPlayer(),r.new) then r.w:SetOwningPlayer(r.old) end
            elseif type(r.new)=='boolean' then
                if r.w[r.key]==r.new then r.w[r.key]=r.old end
            elseif same(r.w[r.key],r.new) then r.w[r.key]=r.old end
        end
    end
    self.changes,self.seen={},{}
end
return Markers
