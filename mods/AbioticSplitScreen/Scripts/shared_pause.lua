-- A separate native visibility hook, with no recurring timer, script predicate
-- hooks, input-map refresh or gameplay cache rewriting from the old v0.7 trial.
local Pause={}
Pause.__index=Pause
local function valid(o) return o~=nil and o:IsValid() end
local function same(a,b) return valid(a) and valid(b) and a:GetAddress()==b:GetAddress() end
local function hide_multiplayer_warning(root,changed)
    local queue,seen={root},{}
    for i=1,256 do
        local w=queue[i]; if not w then break end
        if valid(w) and not seen[w:GetAddress()] then
            seen[w:GetAddress()]=true
            if w:IsA('/Script/UMG.UserWidget') then
                local tree=w.WidgetTree
                if valid(tree) and valid(tree.RootWidget) then queue[#queue+1]=tree.RootWidget end
            elseif w:IsA('/Script/UMG.PanelWidget') then
                local count=w:GetChildrenCount(); assert(count<=256,'Pause panel too large')
                for j=0,count-1 do queue[#queue+1]=w:GetChildAt(j) end
            elseif w:IsA('/Script/UMG.TextBlock') then
                local text=w:GetText():ToString();local lower=text:lower()
                local warning=(lower:find('multiplayer',1,true) and lower:find('paus',1,true)) or
                    (lower:find('single',1,true) and lower:find('only',1,true) and lower:find('paus',1,true)) or
                    text:find('МНОГОПОЛЬЗОВАТЕЛЬСКАЯ ИГРА',1,true) or
                    text:find('ПАУЗЫ ВОЗМОЖНЫ ТОЛЬКО В ОДИНОЧНОЙ ИГРЕ',1,true)
                if warning then
                    changed[#changed+1]={widget=w,visibility=w:GetVisibility()};w:SetVisibility(1)
                end
            end
        end
    end
    return changed
end
function Pause.new(api) return setmetatable({api=api,generation=0},Pause) end
function Pause:bind()
    local context,first,second=self.api.pair()
    local h=self.api.huds(); assert(h,'HUD pair missing')
    self.entries={}
    for i,hud in ipairs({h.main,h.guest}) do
        local pc=i==1 and first or second
        local escape=hud.W_EscapeMenu_Main
        assert(valid(escape) and same(hud:GetOwningPlayer(),pc) and same(escape:GetOwningPlayer(),pc),'Pause widget owner changed')
        self.entries[escape:GetAddress()]={hud=hud,escape=escape,pc=pc,world=context.world}
    end
    self:install()
end
function Pause:install()
    if self.hook then return end
    local path='/Script/UMG.Widget:SetVisibility'
    local f=self.api.find(path)
    assert(valid(f) and (f:GetFunctionFlags() & 0x400)~=0,'Native visibility API missing')
    local n=0
    f:ForEachProperty(function(p)
        n=n+1
        assert(n==1 and p:GetFName():ToString()=='InVisibility' and
            (p:GetFullName():match('^EnumProperty ') or p:GetFullName():match('^ByteProperty ')),'Unexpected visibility signature')
    end)
    assert(n==1,'Visibility signature incomplete')
    local pre,post=self.api.hook(path,function() end,function(context)
        if self.transitioning or not self.entries then return end
        local ok,message=pcall(function()
            local o=context:get()
            if valid(o) and self.entries[o:GetAddress()] then self:schedule() end
        end)
        if not ok then self.api.log('SHAREDPAUSE visibility callback skipped: '..tostring(message)) end
    end)
    self.hook={pre,post}
    self.api.log('SHAREDPAUSE native owned-menu visibility hook installed')
end
function Pause:schedule()
    if self.pending then return end
    self.pending=true; local ticket=self.generation
    self.api.game_thread(function()
        if ticket~=self.generation then return end
        self.pending=false
        local ok,message=pcall(function() self:sync() end)
        if not ok then self.api.log('SHAREDPAUSE stopped: '..tostring(message)) end
    end)
end
function Pause:enter(entry)
    local context=self.api.pair()
    assert(same(context.world,entry.world),'Pause world changed')
    local subsystem=self.api.find_first('GameViewportSubsystem')
    assert(valid(subsystem),'Viewport subsystem unavailable')
    local slot=subsystem:GetWidgetSlot(entry.hud)
    assert(type(slot.ZOrder)=='number','HUD slot unavailable')
    local r={entry=entry,subsystem=subsystem,slot=slot,z=slot.ZOrder,paused_by_us=false}
    self.active=r; self.transitioning=true
    local ok,message=pcall(function()
        local visibility=entry.escape:GetVisibility()
        entry.hud:RemoveFromParent()
        entry.hud:AddToViewport(10000)
        assert(entry.hud:IsInViewport(),'Fullscreen HUD insertion failed')
        entry.escape:SetVisibility(visibility)
        self.api.focus(entry.pc,entry.escape)
        if not context.statics:IsGamePaused(context.world) then
            local accepted=context.statics:SetGamePaused(context.world,true)
            r.paused_by_us=context.statics:IsGamePaused(context.world)==true
            self.api.log('SHAREDPAUSE engine accepted='..tostring(accepted)..'; world paused='..tostring(r.paused_by_us))
        else self.api.log('SHAREDPAUSE world was already paused; existing pause retained') end
        if context.statics:IsGamePaused(context.world) then
            r.warnings={}
            local checked,warnings=pcall(hide_multiplayer_warning,entry.escape,r.warnings)
            if not checked then self.api.log('SHAREDPAUSE warning scan stopped: '..tostring(warnings)) end
        end
        self.api.log('SHAREDPAUSE menu moved to full viewport; verify Resume/Esc and both players in game')
    end)
    self.transitioning=false
    if not ok then
        local restored,why=pcall(function() self:leave() end)
        if not restored then self.api.log('SHAREDPAUSE rollback failed: '..tostring(why)) end
        error(message)
    end
end
function Pause:leave()
    local r=self.active
    if not r then return end
    local context=self.api.pair()
    assert(same(context.world,r.entry.world),'Old pause will not be applied to another world')
    self.transitioning=true
    local ok,message=pcall(function()
        if r.paused_by_us and context.statics:IsGamePaused(context.world) then
            assert(context.statics:SetGamePaused(context.world,false)==true,'Engine refused to unpause')
            assert(not context.statics:IsGamePaused(context.world),'World is still paused')
            r.paused_by_us=false
        end
        local e=r.entry
        assert(valid(e.hud) and valid(e.escape),'Pause HUD expired')
        local visibility=e.escape:GetVisibility()
        e.hud:RemoveFromParent()
        assert(e.hud:AddToPlayerScreen(r.z)==true,'Player HUD restoration failed')
        r.subsystem:SetWidgetSlot(e.hud,r.slot)
        e.escape:SetVisibility(visibility)
        for _,warning in ipairs(r.warnings or {}) do
            if valid(warning.widget) and warning.widget:GetVisibility()==1 then warning.widget:SetVisibility(warning.visibility) end
        end
        self.active=nil
        self.api.unfocus(e.pc)
        self.api.log('SHAREDPAUSE split HUD restored; mod-owned pause released')
    end)
    self.transitioning=false
    if not ok then error(message) end
end
function Pause:sync()
    if self.transitioning or not self.entries then return end
    if self.active then
        if not self.api.visible(self.active.entry.escape) then self:leave() end
        return
    end
    for _,entry in pairs(self.entries) do
        if self.api.visible(entry.escape) then self:enter(entry); return end
    end
end
function Pause:key()
    if not self.active then self:check_later(); return end
    local record,ticket=self.active,self.generation
    self.api.delay(120,function()
        self.api.game_thread(function()
            if self.active~=record or ticket~=self.generation then return end
            local ok,message=pcall(function()
                if self.api.visible(record.entry.escape) then
                    local f=self.api.find('/Game/Blueprints/Meta/Abiotic_PlayerController.Abiotic_PlayerController_C:CloseEscapeMenuAndResumeGame')
                    assert(valid(f),'Owned native menu close entry point unavailable; use Resume')
                    f:ForEachProperty(function(p)
                        local key=p:GetFName():ToString()
                        assert(key:match('^CallFunc_') or key:match('^K2Node_') or key:match('^Temp_'),
                            'Unexpected menu close argument: '..key)
                    end)
                    f(record.entry.pc)
                end
                self:sync()
            end)
            if not ok then self.api.log('SHAREDPAUSE Esc fallback skipped: '..tostring(message)) end
        end)
    end)
end
function Pause:check_later()
    local ticket=self.generation
    self.api.delay(120,function()
        self.api.game_thread(function()
            if ticket~=self.generation or not self.entries then return end
            local ok,message=pcall(function() self:sync() end)
            if not ok then self.api.log('SHAREDPAUSE deferred check skipped: '..tostring(message)) end
        end)
    end)
end
function Pause:restore()
    self.generation=self.generation+1; self.pending=false
    if self.active then self:leave() end
    self.entries=nil
end
return Pause
