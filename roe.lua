-- roe.lua – RoE profile helper (Ashita v4)
-- Author: Original by Cair, ported by Commandobill
-- Description: Create and manage RoE profiles with configurable settings

addon.name    = 'roe'
addon.version = '1.0.1'
addon.author  = 'Original by Cair, ported by Commandobill'
addon.desc    = 'Create and activate RoE profiles'
addon.link    = 'https://github.com/commandobill/roe'

local config    = require('settings')
local chat      = require('chat')
local struct    = require('struct')
local bit       = require('bit')
local coroutine = coroutine
local roe_mapping = require('roe_mapping')

-- Print error message
local function eprint(msg) print(chat.header('roe') .. chat.error(msg)) end

-- Print normal message
local function nprint(msg) print(chat.header('roe') .. chat.message(msg)) end

-- Fuzzy string matching function using Ashita v4 string utilities
local function fuzzy_match(search_term, target_string)
    -- Normalize strings: lowercase, remove punctuation, clean whitespace
    search_term = search_term:lower():gsub('[%p]+', ' '):clean()
    target_string = target_string:lower():gsub('[%p]+', ' '):clean()
    
    -- Split into words using Ashita's split function
    local search_words = search_term:split(' ')
    local target_words = target_string:split(' ')
    
    -- Debug: Print detailed matching info for crystal objectives
    if target_string:find('crystal') and search_term:find('crystal') then
        nprint(('Debug fuzzy_match: search="%s" target="%s"'):format(search_term, target_string))
        nprint(('Debug: search_words=%s'):format(table.concat(search_words, ',')))
        nprint(('Debug: target_words=%s'):format(table.concat(target_words, ',')))
    end
    
    -- Check if all search words are found in target using exact word matches
    local matches = 0
    local total_possible_matches = 0
    
    for _, search_word in ipairs(search_words) do
        if search_word:len() > 0 then  -- Skip empty words
            total_possible_matches = total_possible_matches + 1
            for _, target_word in ipairs(target_words) do
                -- Use exact word match instead of contains for better precision
                if target_word == search_word then
                    matches = matches + 1
                    break
                end
            end
        end
    end
    
    -- Calculate final score
    local final_score
    if matches == total_possible_matches then
        -- All search words found - this is a perfect match regardless of extra words
        final_score = 1.0
    else
        -- Partial match - score based on percentage of search words found
        final_score = matches / total_possible_matches
    end
    
    -- Debug: Print score for crystal objectives
    if target_string:find('crystal') and search_term:find('crystal') then
        nprint(('Debug: matches=%d/%d, final_score=%.2f'):format(matches, total_possible_matches, final_score))
    end
    
    return final_score
end

-- Find RoE objectives by name using fuzzy matching
local function find_roe_by_name(search_term, require_all_words)
    local results = {}
    local min_score = require_all_words and 1.0 or 0.5  -- Require 100% match for bulk operations
    
    -- Debug: Print search term and min_score
    nprint(('Debug: Searching for "%s" with min_score %.1f'):format(search_term, min_score))
    
    for id, name in pairs(roe_mapping) do
        local score = fuzzy_match(search_term, name)
        if score >= min_score then
            results[#results + 1] = {
                id = id,
                name = name,
                score = score
            }
            -- Debug: Print when we add a result
            if name:find('Crystal') then
                nprint(('Debug: Added result %d: "%s" (score=%.2f)'):format(id, name, score))
            end
        end
    end
    
    -- Debug: Print number of results found
    nprint(('Debug: Found %d results'):format(#results))
    
    -- Sort by score (highest first)
    table.sort(results, function(a, b) return a.score > b.score end)
    
    return results
end

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
            local off   = 5 + ((i - 1) * 4)
            local word  = struct.unpack('I', e.data, off)   -- 32-bit LE
            local qid   = bit.band(word, 0xFFF)             -- lower 12 bits
            local prog  = bit.rshift(word, 12)              -- upper 20 bits
            if qid > 0 then
                roe.active[qid] = prog                      -- store progress %
            end
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

-- Add a specific RoE objective by ID or name
local function add_roe(input)
    
    -- Try to parse as number first
    local id = tonumber(input)
    
    if id then
        -- Input is a number, treat as ID
        if roe.complete[id] then 
            local name = roe_mapping[id] or "Unknown"
            eprint(('RoE objective %d (%s) is already completed'):format(id, name))
            return 
        end
        if roe.active[id] then 
            local name = roe_mapping[id] or "Unknown"
            eprint(('RoE objective %d (%s) is already active'):format(id, name))
            return 
        end
        if id >= 4008 and id <= 4021 then 
            local name = roe_mapping[id] or "Unknown"
            eprint(('RoE objective %d (%s) cannot be added (auto hourly objectives)'):format(id, name))
            return 
        end
        
        accept_roe(id)
        local name = roe_mapping[id] or "Unknown"
        nprint(('Added RoE objective %d: %s'):format(id, name))
    else
        -- Input is not a number, treat as name search
        local results = find_roe_by_name(input)
        
        if #results == 0 then
            eprint(('No RoE objectives found matching "%s"'):format(input))
            return
        elseif #results == 1 then
            local result = results[1]
            if roe.complete[result.id] then 
                eprint(('RoE objective %d (%s) is already completed'):format(result.id, result.name))
                return 
            end
            if roe.active[result.id] then 
                eprint(('RoE objective %d (%s) is already active'):format(result.id, result.name))
                return 
            end
            if result.id >= 4008 and result.id <= 4021 then 
                eprint(('RoE objective %d (%s) cannot be added (restricted range)'):format(result.id, result.name))
                return 
            end
            
            accept_roe(result.id)
            nprint(('Added RoE objective %d: %s'):format(result.id, result.name))
        else
            -- Multiple matches found - check if there's a 100% match
            local perfect_match = nil
            for _, result in ipairs(results) do
                if result.score == 1.0 then
                    perfect_match = result
                    break
                end
            end
            
            if perfect_match then
                -- Use the perfect match automatically
                if roe.complete[perfect_match.id] then 
                    eprint(('RoE objective %d (%s) is already completed'):format(perfect_match.id, perfect_match.name))
                    return 
                end
                if roe.active[perfect_match.id] then 
                    eprint(('RoE objective %d (%s) is already active'):format(perfect_match.id, perfect_match.name))
                    return 
                end
                if perfect_match.id >= 4008 and perfect_match.id <= 4021 then 
                    eprint(('RoE objective %d (%s) cannot be added (restricted range)'):format(perfect_match.id, perfect_match.name))
                    return 
                end
                
                accept_roe(perfect_match.id)
                nprint(('Added RoE objective %d: %s'):format(perfect_match.id, perfect_match.name))
            else
                -- No perfect match, show multiple results
                eprint(('Multiple RoE objectives found matching "%s":'):format(input))
                for i = 1, math.min(5, #results) do  -- Show top 5 matches
                    local result = results[i]
                    nprint(('  %d: %s (%.0f%% match)'):format(result.id, result.name, result.score * 100))
                end
                if #results > 5 then
                    nprint(('  ... and %d more matches'):format(#results - 5))
                end
                eprint('Please be more specific or use the ID directly.')
            end
        end
    end
end

-- Remove a specific RoE objective by ID or name
local function rem_roe(input)
    -- Check if we have 0 active RoEs (status needs refresh)
    if roe.active:length() == 0 then
        eprint('No active RoE objectives detected. Please add an RoE objective to refresh the status.')
        return
    end
    
    -- Try to parse as number first
    local id = tonumber(input)
    
    if id then
        -- Input is a number, treat as ID
        if not roe.active[id] then 
            local name = roe_mapping[id] or "Unknown"
            eprint(('RoE objective %d (%s) is not currently active'):format(id, name))
            return 
        end
        if roe.settings.blacklist[id] then
            local name = roe_mapping[id] or "Unknown"
            eprint(('RoE objective %d (%s) is blacklisted and cannot be removed'):format(id, name))
            return 
        end
        
        cancel_roe(id)
        local name = roe_mapping[id] or "Unknown"
        nprint(('Removed RoE objective %d: %s'):format(id, name))
    else
        -- Input is not a number, treat as name search
        local results = find_roe_by_name(input)
        
        if #results == 0 then
            eprint(('No RoE objectives found matching "%s"'):format(input))
            return
        elseif #results == 1 then
            local result = results[1]
            if not roe.active[result.id] then 
                eprint(('RoE objective %d (%s) is not currently active'):format(result.id, result.name))
                return 
            end
            if roe.settings.blacklist[result.id] then
                eprint(('RoE objective %d (%s) is blacklisted and cannot be removed'):format(result.id, result.name))
                return 
            end
            
            cancel_roe(result.id)
            nprint(('Removed RoE objective %d: %s'):format(result.id, result.name))
        else
            -- Multiple matches found - check if there's a 100% match
            local perfect_match = nil
            for _, result in ipairs(results) do
                if result.score == 1.0 then
                    perfect_match = result
                    break
                end
            end
            
            if perfect_match then
                -- Use the perfect match automatically
                if not roe.active[perfect_match.id] then 
                    eprint(('RoE objective %d (%s) is not currently active'):format(perfect_match.id, perfect_match.name))
                    return 
                end
                if roe.settings.blacklist[perfect_match.id] then
                    eprint(('RoE objective %d (%s) is blacklisted and cannot be removed'):format(perfect_match.id, perfect_match.name))
                    return 
                end
                
                cancel_roe(perfect_match.id)
                nprint(('Removed RoE objective %d: %s'):format(perfect_match.id, perfect_match.name))
            else
                -- No perfect match, show multiple results
                eprint(('Multiple RoE objectives found matching "%s":'):format(input))
                for i = 1, math.min(5, #results) do  -- Show top 5 matches
                    local result = results[i]
                    local status = ""
                    if not roe.active[result.id] then
                        status = " (not active)"
                    elseif roe.settings.blacklist[result.id] then
                        status = " (blacklisted)"
                    end
                    nprint(('  %d: %s (%.0f%% match)%s'):format(result.id, result.name, result.score * 100, status))
                end
                if #results > 5 then
                    nprint(('  ... and %d more matches'):format(#results - 5))
                end
                eprint('Please be more specific or use the ID directly.')
            end
        end
    end
end

-- Add multiple RoE objectives by name using fuzzy matching
local function addall_roe(input)
    
    -- Only works with name search, not ID
    local id = tonumber(input)
    if id then
        eprint('addall: use "add" command for specific ID numbers')
        return
    end
    
    -- Search for matches (require all words to match for bulk operations)
    local results = find_roe_by_name(input, true)
    
    if #results == 0 then
        eprint(('No RoE objectives found matching "%s"'):format(input))
        return
    elseif #results > 10 then
        eprint(('Too many RoE objectives found matching "%s" (%d matches)'):format(input, #results))
        eprint('Showing first 10 matches:')
        for i = 1, 10 do
            local result = results[i]
            local status = ""
            if roe.complete[result.id] then
                status = " (completed)"
            elseif roe.active[result.id] then
                status = " (active)"
            elseif result.id >= 4008 and result.id <= 4021 then
                status = " (restricted)"
            end
            nprint(('  %d: %s (%.0f%% match)%s'):format(result.id, result.name, result.score * 100, status))
        end
        eprint('Please be more specific or use individual IDs.')
        return
    end
    
    -- Check available slots
    local available_slots = roe.max_count - roe.active:length()
    local objectives_to_add = 0
    
    -- Count how many objectives we can actually add
    for _, result in ipairs(results) do
        if not roe.complete[result.id] and not roe.active[result.id] and not (result.id >= 4008 and result.id <= 4021) then
            objectives_to_add = objectives_to_add + 1
        end
    end
    
    if objectives_to_add > available_slots then
        eprint("not enough free ROE slots. Additional slots needed: " .. (objectives_to_add - available_slots))
        eprint(('Found %d objectives to add, but only %d slots available'):format(objectives_to_add, available_slots))
        return
    end
    
    -- Process all matches
    local added_count = 0
    local skipped_count = 0
    local skipped_reasons = {}
    
    for _, result in ipairs(results) do
        if roe.complete[result.id] then 
            skipped_count = skipped_count + 1
            skipped_reasons[#skipped_reasons + 1] = ('%d (%s) - already completed'):format(result.id, result.name)
        elseif roe.active[result.id] then 
            skipped_count = skipped_count + 1
            skipped_reasons[#skipped_reasons + 1] = ('%d (%s) - already active'):format(result.id, result.name)
        elseif result.id >= 4008 and result.id <= 4021 then 
            skipped_count = skipped_count + 1
            skipped_reasons[#skipped_reasons + 1] = ('%d (%s) - restricted range'):format(result.id, result.name)
        else
            accept_roe(result.id)
            coroutine.sleep(0.5)
            added_count = added_count + 1
        end
    end
    
    -- Report results
    if added_count > 0 then
        nprint(('Added %d RoE objectives matching "%s"'):format(added_count, input))
    end
    
    if skipped_count > 0 then
        eprint(('Skipped %d objectives:'):format(skipped_count))
        for _, reason in ipairs(skipped_reasons) do
            eprint(('  %s'):format(reason))
        end
    end
    
    if added_count == 0 and skipped_count == 0 then
        eprint(('No objectives were processed for "%s"'):format(input))
    end
end

-- Remove multiple RoE objectives by name using fuzzy matching
local function remall_roe(input)
    -- Check if we have 0 active RoEs (status needs refresh)
    if roe.active:length() == 0 then
        eprint('No active RoE objectives detected. Please add an RoE objective to refresh the status.')
        return
    end
    
    -- Only works with name search, not ID
    local id = tonumber(input)
    if id then
        eprint('remall: use "rem" command for specific ID numbers')
        return
    end
    
    -- Search for matches (require all words to match for bulk operations)
    local results = find_roe_by_name(input, true)
    
    if #results == 0 then
        eprint(('No RoE objectives found matching "%s"'):format(input))
        return
    elseif #results > 10 then
        eprint(('Too many RoE objectives found matching "%s" (%d matches)'):format(input, #results))
        eprint('Showing first 10 matches:')
        for i = 1, 10 do
            local result = results[i]
            local status = ""
            if not roe.active[result.id] then
                status = " (not active)"
            elseif roe.settings.blacklist[result.id] then
                status = " (blacklisted)"
            end
            nprint(('  %d: %s (%.0f%% match)%s'):format(result.id, result.name, result.score * 100, status))
        end
        eprint('Please be more specific or use individual IDs.')
        return
    end
    
    -- Process all matches
    local removed_count = 0
    local skipped_count = 0
    local skipped_reasons = {}
    
    for _, result in ipairs(results) do
        if not roe.active[result.id] then 
            skipped_count = skipped_count + 1
            skipped_reasons[#skipped_reasons + 1] = ('%d (%s) - not currently active'):format(result.id, result.name)
        elseif roe.settings.blacklist[result.id] then
            skipped_count = skipped_count + 1
            skipped_reasons[#skipped_reasons + 1] = ('%d (%s) - blacklisted'):format(result.id, result.name)
        else
            cancel_roe(result.id)
            coroutine.sleep(0.5)
            removed_count = removed_count + 1
        end
    end
    
    -- Report results
    if removed_count > 0 then
        nprint(('Removed %d RoE objectives matching "%s"'):format(removed_count, input))
    end
    
    if skipped_count > 0 then
        eprint(('Skipped %d objectives:'):format(skipped_count))
        for _, reason in ipairs(skipped_reasons) do
            eprint(('  %s'):format(reason))
        end
    end
    
    if removed_count == 0 and skipped_count == 0 then
        eprint(('No objectives were processed for "%s"'):format(input))
    end
end

-- Show current RoE status for debugging
local function show_status()
    nprint('Current RoE Status:')
    nprint(('Active objectives: %d/%d'):format(roe.active:length(), roe.max_count))
    
    if roe.active:length() > 0 then
        nprint('Active objectives:')
        for id, progress in pairs(roe.active) do
            local name = roe_mapping[id] or "Unknown"
            nprint(('  %d: %s (%.0f%% progress)'):format(id, name, progress))
        end
    else
        nprint('No active objectives found')
    end
    
    nprint(('Completed objectives: %d'):format(roe.complete:length()))
    nprint(('Blacklisted objectives: %d'):format(table.getn(roe.settings.blacklist)))
    
    -- Note: Status refresh requires adding an RoE objective
    nprint('Note: If status appears incorrect, add an RoE objective to refresh the status.')
end

-- Print help text to chat
local function help()
    nprint([[
ROE - Command List

/roe help
    Show this help menu.

/roe add <id or name>
    Add a specific ROE objective by its ID number or name.
    Examples:
    /roe add 77
    /roe add "spoils light crystal"
    /roe add "vanquish enemy"

/roe rem <id or name>
    Remove a specific ROE objective by its ID number or name.
    Examples:
    /roe rem 77
    /roe rem "spoils light crystal"
    /roe rem "vanquish enemy"

/roe addall <name>
    Add all ROE objectives matching the name (max 10 matches).
    Examples:
    /roe addall "crystal"
    /roe addall "vanquish"

/roe remall <name>
    Remove all ROE objectives matching the name (max 10 matches).
    Examples:
    /roe remall "crystal"
    /roe remall "vanquish"

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

/roe status
    Show current RoE status. If no active objectives are shown, add an RoE objective to refresh the status.
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
    add       = add_roe,
    rem       = rem_roe,
    addall    = addall_roe,
    remall    = remall_roe,
    status    = show_status,
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
        nprint('RoE addon loaded. Add an RoE objective to refresh status if needed.')
        _startup.sent = true
    end
end)
