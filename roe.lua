-- roe.lua – RoE profile helper (Ashita v4)
-- Author: Original by Cair, ported by Commandobill
-- Description: Create and manage RoE profiles with configurable settings

addon.name    = 'roe'
addon.version = '1.0'
addon.author  = 'Original by Cair, ported by Commandobill'
addon.desc    = 'Create and activate RoE profiles'
addon.link    = 'https://github.com/commandobill/roe'

local config    = require('settings')
local chat      = require('chat')
local struct    = require('struct')
local bit       = require('bit')
local coroutine = coroutine

-- Print error message
local function eprint(msg) print(chat.header('roe') .. chat.error(msg)) end

-- Print normal message
local function nprint(msg) print(chat.header('roe') .. chat.message(msg)) end

-- Send RoE packet with a given packet ID and objective ID
local function send_roe_packet(pid, roe_id)
    local pkt = struct.pack('bbbbHbb', pid, 0x04, 0x00, 0x00, roe_id, 0x00, 0x00):totable()
    AshitaCore:GetPacketManager():AddOutgoingPacket(pid, pkt)
end

-- Create a new set object with utility methods
local function _new_set(values)
    local self = {}
    if values then for _, v in pairs(values) do self[v] = true end end
    local mt = {}

    function mt.__index(t, k)
        if     k == 'add'          then return function(_, v) t[v] = true end
        elseif k == 'remove'       then return function(_, v) t[v] = nil end
        elseif k == 'contains'     then return function(_, v) return t[v] end
        elseif k == 'length'       then return function() local c = 0; for _ in pairs(t) do c = c + 1 end; return c end
        elseif k == 'keyset'       then return function() local r = S{}; for v in pairs(t) do r:add(v) end; return r end
        elseif k == 'update'       then return function(_, o) for v in pairs(o) do t[v] = true end end
        elseif k == 'diff'         then return function(_, o) local r = S{}; for v in pairs(t) do if not o[v] then r:add(v) end end; return r end
        elseif k == 'intersection' then return function(_, o) local r = S{}; for v in pairs(t) do if o[v] then r:add(v) end end; return r end
        elseif k == 'union'        then return function(_, o) local r = S{}; r:update(t); r:update(o); return r end
        elseif k == 'it'           then return function() local k; return function() k = next(t, k); return k end end
        end
    end

    return setmetatable(self, mt)
end

-- Global S constructor for sets
S = setmetatable({}, { __call = function(_, iter) return _new_set(iter) end })

-- Convert input into a Set object
local function as_set(value)
    if type(value) == 'string' then
        local arr = {}; for id in value:gmatch('%d+') do arr[#arr+1] = tonumber(id) end
        return S(arr)
    elseif type(value) == 'table' then
        if value.diff then return value end -- Already a Set
        local arr = {}
        for k, v in pairs(value) do
            if type(k) == 'number' and v == true then arr[#arr+1] = k
            elseif type(v) == 'number' then arr[#arr+1] = v end
        end
        return S(arr)
    end
    return S{}
end

-- Default configuration settings
local defaults = T{
    profiles      = { default = S{} },
    blacklist     = T{},
    clear         = true,
    clearprogress = false,
    clearall      = false,
}

-- State management
local roe = T{
    active    = S{},
    complete  = S{},
    max_count = 30,
    settings  = config.load(defaults)
}

-- Register settings update handler
config.register('settings', 'settings_update', function(s)
    if s then roe.settings = s end
    config.save()
end)

-- Cancel a specific RoE objective
local function cancel_roe(id)
    id = tonumber(id)
    if not id or roe.settings.blacklist[id] or not roe.active[id] then return end
    send_roe_packet(0x10D, id)
end

-- Accept a specific RoE objective
local function accept_roe(id)
    id = tonumber(id)
    if not id or roe.complete[id] or roe.active[id] then return end
    if id >= 4008 and id <= 4021 then return end
    send_roe_packet(0x10C, id)
end

-- Save current active RoE objectives as a profile
local function save_profile(name)
    if type(name) ~= 'string' then eprint('save: specify a profile name') return end
    name = name:lower()
    local list, n = {}, 0
    for id in pairs(roe.active) do n = n + 1; list[n] = id end
    roe.settings.profiles[name] = S(list)
    config.save()
    nprint(('saved %d objectives to profile %s'):format(n, name))
end

-- List all saved RoE profiles
local function list_profiles()
    nprint('Profiles: ' .. table.concat((function()
        local out = {}; for k in pairs(roe.settings.profiles) do out[#out+1] = k end
        table.sort(out); return out end)(), ', '))
end

-- Set and apply a saved profile of RoE objectives
local function set_profile(name)
    if type(name) ~= 'string' then eprint('set: specify a profile name') return end
    name = name:lower()
    local prof = as_set(roe.settings.profiles[name])
    if prof:length() == 0 then eprint(('set: profile "%s" does not exist or is empty'):format(name)) return end

    local have   = roe.active:keyset()
    local need   = prof:diff(have)
    local slots  = roe.max_count - roe.active:length()
    local remove = S{}

    if roe.settings.clearall then
        remove:update(have)
    elseif roe.settings.clear then
        for id, prog in pairs(roe.active) do
            if (need:length() - remove:length()) <= slots then break end
            if (prog == 0 or roe.settings.clearprogress) and not roe.settings.blacklist[id] then
                remove:add(id)
            end
        end
    end

    local remaining = need:length() - remove:length()
    if remaining > slots then
        eprint("not enough free ROE slots. Additional slots needed: " .. remaining - slots)
        return
    end

    for id in remove:it() do cancel_roe(id); coroutine.sleep(0.5) end
    for id in need:it()   do accept_roe(id); coroutine.sleep(0.5) end
    nprint(('loaded profile "%s"'):format(name))
end

-- Unset active objectives or those in a given profile
local function unset_profile(name)
    name = name and name:lower()
    if name and roe.settings.profiles[name] then
        local todo = roe.active:keyset():intersection(roe.settings.profiles[name])
        for id in todo:it() do cancel_roe(id); coroutine.sleep(0.5) end
        nprint(('unset profile "%s"'):format(name))
    elseif name then
        eprint(('unset: profile "%s" does not exist'):format(name))
    else
        nprint('clearing ROE objectives...')
        for id, prog in pairs(roe.active) do
            if prog == 0 or roe.settings.clearprogress then cancel_roe(id); coroutine.sleep(0.5) end
        end
        nprint('ROE objectives cleared...')
    end
end

-- Handle incoming RoE packets
ashita.events.register('packet_in','roe_in', function(e)
    if e.id == 0x111 then
        roe.active = S{}
        for i = 1, roe.max_count do
            local off  = 5 + ((i - 1) * 4)
            local qid  = struct.unpack('h', e.data, off)
            local prog = struct.unpack('h', e.data, off + 2)
            if qid > 0 then roe.active[qid] = prog end
        end
    elseif e.id == 0x112 then
        local done = S{}
        local offset_val = struct.unpack('H', e.data, 133)
        for i = 0, 1023 do
            local byte = e.data:byte(5 + math.floor(i / 8))
            if bit.band(byte, bit.lshift(1, i % 8)) ~= 0 then
                done:add(i + offset_val * 1024)
            end
        end
        roe.complete:update(done)
    end
end)

local true_strings  = S{'true','t','y','yes','on'}
local false_strings = S{'false','f','n','no','off'}
local bool_strings  = true_strings:union(false_strings)

-- Handle toggle settings command
local function handle_setting(name, val)
    if type(name) ~= 'string' then eprint('settings: specify a setting name'); return end
    name = name:lower()
    if roe.settings[name] == nil then eprint(('settings: "%s" does not exist'):format(name)); return end
    if type(roe.settings[name]) ~= 'boolean' then eprint(('settings: "%s" is not a toggle'):format(name)); return end
    val = val and val:lower()
    if not val or not bool_strings:contains(val) then
        roe.settings[name] = not roe.settings[name]
    elseif true_strings:contains(val) then
        roe.settings[name] = true
    else
        roe.settings[name] = false
    end
    nprint(('setting "%s" is now %s'):format(name, tostring(roe.settings[name])))
    config.save()
end

-- Handle blacklist add/remove command
local function blacklist(action, id)
    action = action and action:lower()
    id = tonumber(id)
    if not (action and id) then eprint('blacklist usage: blacklist [add|remove] <id>'); return end
    if action == 'add' then
        roe.settings.blacklist[id] = true
        nprint(('quest %d added to blacklist'):format(id))
    elseif action == 'remove' then
        if id >= 4008 and id <= 4021 then return end
        roe.settings.blacklist[id] = nil
        nprint(('quest %d removed from blacklist'):format(id))
    else
        eprint('blacklist: first arg must be "add" or "remove"')
    end
    config.save()
end

-- Print help text to chat
local function help()
    nprint([[
ROE - Command List

/roe help
    Show this help menu.

/roe save <profile name>
    Save your currently set ROE objectives to a named profile.

/roe set <profile name>
    Load and apply a saved profile of ROE objectives.
    - Objectives may be canceled automatically based on settings.
    - By default, only incomplete objectives will be removed if space is needed.

/roe unset [<profile name>]
    Remove the currently set ROE objectives.
    - Without a name, it will only remove objectives with no progress.
    - If a profile is specified, it removes only those objectives.

/roe list
    List all saved profile names.

/roe settings <name> [true|false]
    Toggle a settings value, or set it explicitly.
    * clear         : Remove inactive objectives if needed (default: true)
    * clearprogress : Also remove in-progress objectives (default: false)
    * clearall      : Clear all objectives before loading (default: false)

/roe blacklist [add|remove] <id>
    Add or remove a quest from the blacklist.
    - Blacklisted objectives will not be removed automatically.
]])
end

-- Command dispatch table
local handlers = {
    save      = save_profile,
    list      = list_profiles,
    set       = set_profile,
    unset     = unset_profile,
    settings  = handle_setting,
    blacklist = blacklist,
    help      = help,
}

-- Ashita command event
ashita.events.register('command','roe_cmd',function(e)
    local a = e.command:args(); if #a == 0 or a[1]:lower() ~= '/roe' then return end
    e.blocked = true
    local sub = a[2] and a[2]:lower() or 'help'
    if handlers[sub] then handlers[sub](table.unpack(a, 3))
    else nprint(('unknown roe sub-command: %s'):format(sub)) end
end)

-- Build empty 0x112 packet to request RoE status
local function request_roe_refresh()
    local pkt = struct.pack('bbb', 0x112, 0x00, 0x00):totable()
    AshitaCore:GetPacketManager():AddOutgoingPacket(0x112, pkt)
    nprint('Requested RoE status refresh (startup).')
end

-- Check if world state is ready
local function is_world_ready()
    local player = AshitaCore:GetMemoryManager():GetPlayer()
    local player_ent = GetPlayerEntity()
    return not (player == nil or player.isZoning or player_ent == nil)
end

-- Initial load event
local _startup = { sent = false }
ashita.events.register('load','roe_load',function()
    for name, prof in pairs(roe.settings.profiles) do
        if type(prof) == 'string' then
            local arr = {}; for id in prof:gmatch('%d+') do arr[#arr+1] = tonumber(id) end
            roe.settings.profiles[name] = S(arr)
        end
    end
    if _startup.sent then return end
    if is_world_ready() then
        request_roe_refresh()
        _startup.sent = true
    end
end)
