-- Read-only native-array guards, bounded export and integrity framing.
local Probe=require('script_probe')
local passed,serial=0,0x100000
local ALIAS='AbioticSplitScreen_ReadOnlyScriptBytes_v2_'
local function object()
    serial=serial+0x1000;local o={address=serial}
    function o:IsValid() return not self.dead end
    function o:GetAddress() return self.address end
    return o
end
local function class(list)
    local c=object();c.list=list or {}
    function c:ForEachFunction(cb) for _,f in ipairs(self.list) do if cb(f) then break end end end
    function c:GetSuperStruct() return nil end
    return c
end
local function_class=class()
local function fn(name,bytes,flags)
    local f=object();f.reads=0;f.bytes=bytes or {};f.flags=flags or 0;f.name=name;f.views={}
    function f:GetClass() return function_class end
    function f:GetFullName() return 'Function Fixture:'..self.name end
    function f:GetFunctionFlags() return self.flags end
    function f:GetFName() return {ToString=function() return name end,GetComparisonIndex=function() return 100 end} end
    function f:ForEachProperty() end
    local a={}
    function a:GetArrayAddress() return f.address+0x60+(f.wrong_address and 1 or 0) end
    function a:GetArrayNum() return f.n or #f.bytes end
    function a:GetArrayMax() return f.max or #f.bytes end
    function a:GetArrayDataAddress() return f.data or 0x1000000 end
    setmetatable(a,{__index=function(_,i)
        assert(type(i)=='number' and i>=1 and i<=#f.bytes,'Out-of-bounds GET would mutate native TArray')
        f.reads=f.reads+1
        if f.change_during_read then f.n=#f.bytes-1 end
        return f.bytes[i]
    end,__newindex=function() error('Array must never be written') end})
    f.array=a
    -- Match the actual custom-property owner lookup: this UFunction IS the
    -- UStruct being queried. Metadata on its UClass does not apply to it.
    setmetatable(f,{__index=function(_,key)
        if f.views[key] then return f.array end
    end,__call=function() error('Function must never be called') end})
    return f
end
local function fixture()
    local f={logs={},registered=0,registrations={},header='Git SHA #1ba38db4\nUStruct::Script = 0x60\nUsing engine version: 5.4\nUStruct::Script = 0x60'}
    f.native=fn('GetPlayerController',{},0x400);f.native_class=function_class
    function f.native:GetClass() return f.native_class end
    f.body=fn('ExecuteUbergraph_Container',{0x25,0x53})
    f.container_class=class({f.body});f.root_class=class()
    f.first,f.second=object(),object();f.first.Pawn,f.second.Pawn=object(),object()
    f.root,f.container,f.component=object(),object(),object()
    function f.root:GetOwningPlayer() return f.second end
    function f.root:GetClass() return f.root_class end
    function f.container:GetOwningPlayer() return f.second end
    function f.container:GetClass() return f.container_class end
    function f.component:IsA(s) return s=='/Script/Engine.ActorComponent' end
    f.root.ActiveContainer=f.component;f.root.CurrentContainerWidget=f.container
    f.second.Pawn.InventoryReference=f.root
    f.types={ArrayProperty={Name='ArrayProperty',Size=16},ByteProperty={Name='ByteProperty',Size=1}}
    local function find(path)
        if path=='/Script/CoreUObject.Function' then return f.native_class end
        if path=='/Script/Engine.GameplayStatics:GetPlayerController' or path=='Fixture:GetPlayerController' then return f.native end
        for _,c in ipairs({f.container_class,f.root_class}) do
            for _,candidate in ipairs(c.list) do
                if path==candidate:GetFullName():sub(10) then return f.wrong_resolution and f.native or candidate end
            end
        end
    end
    f.probe=Probe.new({pair=function() return {},f.first,f.second end,
        huds=function() return {guest={W_PlayerInventory_Main=f.root}} end,
        header=function() return f.header end,types=f.types,
        find=find,
        register=function(info)
            assert(info.Name:sub(1,#ALIAS)==ALIAS and info.Type==f.types.ArrayProperty and info.OffsetInternal==0x60)
            assert(info.ArrayProperty.Type==f.types.ByteProperty)
            f.registered=f.registered+1
            f.registrations[#f.registrations+1]=info
            if f.reject_registration then error('Injected metadata registration failure') end
            local owner=find(info.BelongsToClass)
            -- A UClass metadata owner is deliberately NOT applied to functions.
            if owner and owner~=f.native_class then owner.views[info.Name]=true end
        end,log=function(s) f.logs[#f.logs+1]=s end})
    return f
end
local function test(name,cb) cb();passed=passed+1;print('PASS '..name) end
test('report reads only in-bounds bytes and emits verified framing once',function()
    local f=fixture();assert(f.registered==0);f.probe:dump()
    local log=table.concat(f.logs,'\n')
    assert(log:find('data=2553',1,true) and log:find('adler32=009f0079',1,true))
    assert(log:find('REPORT-END scripts=1 bytes=2',1,true) and f.body.reads==2 and f.native.reads==0)
    f.probe:dump();assert(f.registered==2 and f.body.reads==2)
end)
test('unvalidated build, engine, offset, conflicting offsets reject before registration',function()
    for _,header in ipairs({'','Git SHA #other',
        'Git SHA #1ba38db4 Using engine version: 5.3 UStruct::Script = 0x60',
        'Git SHA #1ba38db4 Using engine version: 5.4 UStruct::Script = 0x61',
        'Git SHA #1ba38db4 Using engine version: 5.4 UStruct::Script = 0x60 UStruct::Script = 0x70'}) do
        local f=fixture();f.header=header
        assert(not pcall(function() f.probe:dump() end));assert(f.registered==0 and f.body.reads==0)
    end
end)
test('unexpected native property sizes reject before registration',function()
    for _,key in ipairs({'ArrayProperty','ByteProperty'}) do
        local f=fixture();f.types[key].Size=0
        assert(not pcall(function() f.probe:dump() end));assert(f.registered==0)
    end
end)
test('native getter must be native, correctly typed and have an empty Script',function()
    for _,kind in ipairs({'flags','class','nonempty'}) do
        local f=fixture()
        if kind=='flags' then f.native.flags=0 elseif kind=='class' then function f.native:GetClass() return object() end
        else f.native.bytes={0x53} end
        assert(not pcall(function() f.probe:dump() end));assert(f.body.reads==0 and f.native.reads==0)
    end
end)
test('guest context and an owned open container gate every native read',function()
    for _,kind in ipairs({'pawn','root','container','component'}) do
        local f=fixture()
        if kind=='pawn' then f.second.Pawn=f.first.Pawn elseif kind=='root' then f.second.Pawn.InventoryReference=nil
        elseif kind=='container' then function f.container:GetOwningPlayer() return f.first end
        else f.root.ActiveContainer=nil end
        assert(not pcall(function() f.probe:dump() end));assert(f.registered==0 and f.body.reads==0)
    end
end)
test('array metadata, pointer and per-function bound reject before byte access',function()
    for _,kind in ipairs({'address','negative','fractional','max','data','large'}) do
        local f=fixture();f.probe:prepare()
        if kind=='address' then f.body.wrong_address=true elseif kind=='negative' then f.body.n=-1
        elseif kind=='fractional' then f.body.n=1.5 elseif kind=='max' then f.body.max=1048577
        elseif kind=='data' then f.body.data=0 elseif kind=='large' then f.body.n=131073;f.body.max=131073 end
        assert(not pcall(function() f.probe:bytes(f.body) end));assert(f.body.reads==0)
    end
end)
test('array count change aborts before the next potentially unsafe byte read',function()
    local f=fixture();f.probe:prepare();f.body.change_during_read=true
    assert(not pcall(function() f.probe:bytes(f.body) end));assert(f.body.reads==1)
end)
test('invalid byte and missing EndOfScript cannot produce accepted reports',function()
    for _,bytes in ipairs({{300,0x53},{0x25}}) do
        local f=fixture();f.body.bytes=bytes
        assert(not pcall(function() f.probe:dump() end))
        assert(not f.probe.finished and not table.concat(f.logs,'\n'):find('REPORT-END',1,true))
    end
end)
test('empty native arrays are never indexed',function()
    local f=fixture();f.probe:prepare();local b=f.probe:bytes(f.native)
    assert(#b==0 and f.native.reads==0)
end)
test('expired functions reject before their array is read',function()
    local f=fixture();f.probe:prepare();f.body.dead=true
    assert(not pcall(function() f.probe:bytes(f.body) end));assert(f.body.reads==0)
end)
test('more than 24 matching functions are catalogued without premature abort',function()
    local f=fixture()
    for i=1,30 do f.container_class.list[#f.container_class.list+1]=fn('WidgetAction'..i,{0x53}) end
    f.probe:dump();assert(table.concat(f.logs,'\n'):find('REPORT-END scripts=31 bytes=32',1,true))
end)
test('total byte budget prevents reading an additional large body',function()
    local f=fixture();local bytes={};for i=1,131072 do bytes[i]=0x53 end
    f.body.bytes=bytes;local b=fn('Transfer',bytes);local c=fn('TakeAll',bytes)
    f.container_class.list={f.body,b,c};f.probe:dump()
    assert(c.reads==0 and table.concat(f.logs,'\n'):find('REPORT-END scripts=2 bytes=262144',1,true))
end)
test('metadata belongs to each exact function structure, never the Function class',function()
    local f=fixture();f.probe:dump()
    assert(#f.registrations==2 and f.registrations[1].BelongsToClass=='Fixture:GetPlayerController')
    assert(f.registrations[2].BelongsToClass=='Fixture:ExecuteUbergraph_Container')
    assert(f.registrations[1].Name~=f.registrations[2].Name)
    -- Previously the mocked array was always present, concealing this regression.
    for _,info in ipairs(f.registrations) do assert(info.BelongsToClass~='/Script/CoreUObject.Function') end
end)
test('function path resolving to another object blocks registration and byte access',function()
    local f=fixture();f.probe:prepare();f.wrong_resolution=true
    assert(not pcall(function() f.probe:bytes(f.body) end))
    assert(f.registered==1 and f.body.reads==0)
end)
test('metadata registration failure aborts before reading the native Script',function()
    local f=fixture();f.reject_registration=true
    assert(not pcall(function() f.probe:prepare() end))
    assert(f.native.reads==0 and f.body.reads==0 and not f.probe.offset)
end)
test('missing function-owned view is distinct from an address mismatch and never read',function()
    local f=fixture();f.probe:prepare();f.probe:array(f.body)
    f.body.views={}
    local ok,message=pcall(function() f.probe:bytes(f.body) end)
    assert(not ok and message:find('unavailable for the exact function owner',1,true) and f.body.reads==0)
end)
test('per-function metadata is reused across bounded repeated reads',function()
    local f=fixture();f.probe:prepare();f.probe:bytes(f.body);f.probe:bytes(f.body)
    assert(f.registered==2 and f.body.reads==4)
end)
print(passed..' script report checks passed (mock arrays; native compatibility requires game validation).')
