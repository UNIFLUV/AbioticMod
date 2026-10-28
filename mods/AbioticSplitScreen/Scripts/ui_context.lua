-- Route native UI lookups by an actual UMG owner, never by keyboard selection.
-- Pawn/controller/world contexts deliberately retain the game's original rules:
-- treating a guest as the host's local save identity would be unsafe.
local Router={}
Router.__index=Router
local function valid(o) return o~=nil and o:IsValid() end
local function same(a,b) return valid(a) and valid(b) and a:GetAddress()==b:GetAddress() end
local function signature(f,fields)
    assert(valid(f) and (f:GetFunctionFlags() & 0x400)~=0,'Native UI function required')
    local n=0
    f:ForEachProperty(function(p)
        n=n+1; local expected=fields[n]
        assert(expected and p:GetFName():ToString()==expected[1] and
            p:GetFullName():match('^'..expected[2]..' '),'Unexpected UI lookup signature: '..p:GetFullName())
    end)
    assert(n==#fields,'Incomplete UI lookup signature')
end
function Router.new(api) return setmetatable({api=api,hooks={},counts={}},Router) end
function Router:bind()
    local _,first,second=self.api.pair()
    assert(valid(first.Pawn) and valid(second.Pawn) and not same(first.Pawn,second.Pawn),'Distinct local characters required')
    self.first,self.second=first,second
end
function Router:ui_owner(o)
    local seen={}
    for _=1,12 do
        if not valid(o) or seen[o:GetAddress()] then return end
        seen[o:GetAddress()]=true
        if o:IsA('/Script/UMG.UserWidget') then
            local pc=o:GetOwningPlayer()
            if same(pc,self.second) then return self.second end
            if same(pc,self.first) then return self.first end
            if valid(pc) then return end
        elseif not o:IsA('/Script/UMG.Widget') and not o:IsA('/Script/UMG.WidgetTree') then
            return -- No gameplay, shared actor, world, or save-state fallback.
        end
        o=o:GetOuter()
    end
end
function Router:note(kind)
    self.counts[kind]=(self.counts[kind] or 0)+1
    if self.counts[kind]<=3 then self.api.log('UIROUTE '..kind..' routed for an owned guest widget') end
end
function Router:lookup(kind,context,index)
    if self.resolving or not valid(self.second) or not valid(self.first) then return end
    self.resolving=true
    local ok,message=pcall(function()
        if index:get()==0 and same(self:ui_owner(context:get()),self.second) then
            index:set(1); self:note(kind)
        end
    end)
    self.resolving=false
    if not ok and not self.failed then self.failed=true; self.api.log('UIROUTE skipped: '..tostring(message)) end
end
function Router:install()
    local fields={{'WorldContextObject','ObjectProperty'},{'PlayerIndex','IntProperty'},{'ReturnValue','ObjectProperty'}}
    for _,path in ipairs({
        '/Script/Engine.GameplayStatics:GetPlayerController',
        '/Script/Engine.GameplayStatics:GetPlayerCharacter',
        '/Script/Engine.GameplayStatics:GetPlayerPawn',
        '/Script/AbioticFactor.AbioticFunctionLibrary:GetAbioticPlayerCharacter',
    }) do
        if not self.hooks[path] then
            local ok,message=pcall(function()
                signature(self.api.find(path),fields)
                local pre,post=self.api.hook(path,function(_,context,index) self:lookup(path,context,index) end)
                self.hooks[path]={pre,post}
                self.api.log('UIROUTE native UI context hook installed: '..path)
            end)
            if not ok then self.api.log('UIROUTE unavailable: '..path..': '..tostring(message)) end
        end
    end
    local path='/Script/UMG.WidgetLayoutLibrary:ProjectWorldLocationToWidgetPosition'
    if not self.hooks[path] then
        local ok,message=pcall(function()
            signature(self.api.find(path),{{'PlayerController','ObjectProperty'},{'WorldLocation','StructProperty'},
                {'ScreenPosition','StructProperty'},{'bPlayerViewportRelative','BoolProperty'},{'ReturnValue','BoolProperty'}})
            local pre,post=self.api.hook(path,function(_,pc,_,_,relative)
                local checked,why=pcall(function()
                    if valid(self.second) and same(pc:get(),self.second) and relative:get()==false then
                        relative:set(true); self:note('player-relative widget projection')
                    end
                end)
                if not checked and not self.failed then self.failed=true; self.api.log('UIROUTE projection skipped: '..tostring(why)) end
            end)
            self.hooks[path]={pre,post}
        end)
        if not ok then self.api.log('UIROUTE projection unavailable: '..tostring(message)) end
    end
    local clamped='/Script/AbioticFactor.AbioticPlayerController:ProjectWorldToScreenClamped'
    if not self.hooks[clamped] then
        local ok,message=pcall(function()
            signature(self.api.find(clamped),{{'WorldPosition','StructProperty'},{'ScreenPosition','StructProperty'},
                {'ScreenDirection','StructProperty'},{'Padding','StructProperty'},{'bPlayerViewportRelative','BoolProperty'},
                {'bClamp','BoolProperty'},{'ReturnValue','BoolProperty'}})
            local pre,post=self.api.hook(clamped,function(context,_,_,_,_,relative)
                local checked,why=pcall(function()
                    if valid(self.second) and same(context:get(),self.second) and relative:get()==false then
                        relative:set(true); self:note('player-relative clamped projection')
                    end
                end)
                if not checked and not self.failed then self.failed=true;self.api.log('UIROUTE clamped projection skipped: '..tostring(why)) end
            end)
            self.hooks[clamped]={pre,post}
        end)
        if not ok then self.api.log('UIROUTE clamped projection unavailable: '..tostring(message)) end
    end
end
function Router:diagnose()
    for key,n in pairs(self.counts) do self.api.log('UIROUTE count '..key..'='..n) end
    if next(self.counts)==nil then self.api.log('UIROUTE no eligible guest UI calls observed yet') end
end
function Router:restore() self.first,self.second=nil,nil end
return Router
