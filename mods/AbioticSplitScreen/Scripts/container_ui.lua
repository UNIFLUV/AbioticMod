-- A keyboard-test bridge for a proven misroute: E on the guest's actual target
-- opened a previously closed host inventory with that same container component.
-- Never steal a pre-existing host window or guess a container from proximity.
local Bridge={}
Bridge.__index=Bridge
local function valid(o) return o~=nil and o:IsValid() end
local function same(a,b) return valid(a) and valid(b) and a:GetAddress()==b:GetAddress() end
function Bridge.new(api) return setmetatable({api=api,generation=0},Bridge) end
function Bridge:cancel() self.generation=self.generation+1 end
function Bridge:key()
    if not self.api.guest_active() then return end
    local context,first,second=self.api.pair()
    local h=self.api.huds()
    local host,guest=h.main.W_PlayerInventory_Main,h.guest.W_PlayerInventory_Main
    local observed=self.api.states()
    local before=observed and observed[host:GetAddress()]
    local target=second.Pawn.BestInteractable_InteractA
    self:cancel(); local ticket=self.generation
    local world,pawn=context.world,second.Pawn
    self.api.delay(220,function()
        self.api.game_thread(function()
            if ticket~=self.generation or not self.api.guest_active() then return end
            local ok,message=pcall(function()
                local current,a,b=self.api.pair()
                assert(same(current.world,world) and same(a,first) and same(b,second) and same(b.Pawn,pawn),'Interaction context changed')
                if self.api.visible(host) and self.api.visible(host.InventoryMain) and
                    not (self.api.visible(guest) and self.api.visible(guest.InventoryMain)) then
                    assert(before and same(before.root,host) and before.displayed==false,'Host menu was already open or its earlier state is unknown')
                    assert(valid(target),'Guest interaction target was not captured')
                    local component=host.ActiveContainer
                    assert(valid(component) and component:IsA('/Script/Engine.ActorComponent'),'No confirmed container component')
                    local matches=same(component,target) or same(component:GetOwner(),target)
                    assert(matches,'Opened container does not match the guest interaction target')
                    local mode=self.api.mode(host)
                    self.api.close_host(component)
                    self.api.open_guest(component,mode)
                    self.api.log('CONTAINER matching interaction handoff requested for guest')
                    self.api.delay(250,function()
                        self.api.game_thread(function()
                            if ticket~=self.generation or not self.api.guest_active() then return end
                            local settled,why=pcall(function()
                                local active,_,pc=self.api.pair()
                                assert(same(active.world,world) and same(pc,second) and same(pc.Pawn,pawn),'Container close/open context changed')
                                self.api.log('CONTAINER settled; guest displayed='..
                                    tostring(self.api.visible(guest) and self.api.visible(guest.InventoryMain))..
                                    '; matching component='..tostring(same(guest.ActiveContainer,component)))
                                self.api.sync()
                            end)
                            if not settled then self.api.log('CONTAINER completion stopped: '..tostring(why)) end
                        end)
                    end)
                    return
                end
                self.api.sync()
            end)
            if not ok then self.api.log('CONTAINER transfer skipped: '..tostring(message)) end
        end)
    end)
end
return Bridge
