local RuntimeLog=require('runtime_log')
local passed=0
local function test(name,cb) cb();passed=passed+1;print('PASS '..name) end
local source='@C:\\Program Files (x86)\\Steam\\steamapps\\common\\AbioticFactor\\AbioticFactor\\Binaries\\Win64\\ue4ss\\Mods\\AbioticSplitScreen\\Scripts\\main.lua'
test('Windows script path resolves the log beside Mods independently of process CWD',function()
    assert(RuntimeLog.path(source)=='C:/Program Files (x86)/Steam/steamapps/common/AbioticFactor/AbioticFactor/Binaries/Win64/ue4ss/UE4SS.log')
end)
test('POSIX, UNC, mixed separators, renamed mod and case are resolved lexically',function()
    for src,expected in pairs({
        ['@/tmp/game/ue4ss/Mods/Mod/Scripts/main.lua']='/tmp/game/ue4ss/UE4SS.log',
        ['@\\\\server\\share\\game\\ue4ss\\Mods\\Mod\\Scripts\\main.lua']='//server/share/game/ue4ss/UE4SS.log',
        ['@D:/Steam Library/ue4ss/MODS/Other/scripts/MAIN.LUA']='D:/Steam Library/ue4ss/UE4SS.log'
    }) do assert(RuntimeLog.path(src)==expected) end
end)
test('relative chunks, unknown layout and path traversal reject without opening files',function()
    for _,src in ipairs({'main.lua','@Mods/Mod/Scripts/main.lua','@ue4ss/Mods/Mod/Scripts/main.lua',
        '@C:/game/Other/Mod/Scripts/main.lua','@C:/game/Mods/Mod/Other/main.lua',
        '@C:/game/../ue4ss/Mods/Mod/Scripts/main.lua','@C:/game/Mods/../Scripts/main.lua'}) do
        local opened=false
        assert(not pcall(function() RuntimeLog.read(src,function() opened=true end) end));assert(not opened)
    end
end)
test('header is opened read-only, bounded and closed',function()
    local closed=false;local f={}
    function f:read(n) assert(n==262144);return 'Header bytes' end
    function f:close() closed=true end
    local text=RuntimeLog.read(source,function(path,mode)
        assert(path:sub(-10)=='/UE4SS.log' and mode=='rb');return f
    end)
    assert(text=='Header bytes' and closed)
end)
test('open failure retains the native reason and never guesses other paths',function()
    local attempts=0
    local ok,err=pcall(function() RuntimeLog.read(source,function() attempts=attempts+1;return nil,'Permission denied' end) end)
    assert(not ok and err:find('Permission denied',1,true) and attempts==1)
end)
test('read failure still closes the handle and reports the error',function()
    local closed=false
    local ok,err=pcall(function() RuntimeLog.read(source,function() return {
        read=function() error('Injected read failure') end,close=function() closed=true end} end) end)
    assert(not ok and closed and err:find('Injected read failure',1,true))
end)
test('empty header is rejected after closing',function()
    local closed=false
    assert(not pcall(function() RuntimeLog.read(source,function() return {
        read=function() return nil end,close=function() closed=true end} end) end));assert(closed)
end)
print(passed..' runtime log path/read checks passed (mock file handles; actual Windows path still needs validation).')
