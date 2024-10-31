--control.lua

-- registers a new player for inventory monitoring, if player a) not already registered, b) exists, c) is a character, d) has a main inventory.
-- @returns true if player added; false otherwise
local function register_player(player_index)
    if not storage.player_info then
        storage.player_info = {}
    end
    if not storage.forces_researched then
        storage.forces_researched = {}
    end

    if storage.player_info[player_index] then
        return false        -- already registered
    end

    local p = game.get_player(player_index)
    if not (p and p.character and p.get_main_inventory() and p.get_inventory(defines.inventory.character_trash)) then
        return false        -- invalid candidate for trimming
    end

    if not storage.forces_researched[p.force.index] then
        return false        -- player's force hasn't researched relevant techs
    end

    storage.player_info[player_index] = { player = p }
    return true
end

-- De-registers a player from inventory monitoring. They might have left, or we can't find anything more to do.
-- We'll re-register them if their inventory changes.
local function deregister_player(player_index)
    storage.player_info[player_index] = nil
end


-- if both Nil, then Nil; else a+b (treating Nil = 0)
local function minsum(a, b)
    return (a and b) and (a + b) or a or b
end

-- if both Nil, then Nil; else a+b (treating Nil = Inf)
local function maxsum(a, b)
    return (a and b) and (a + b) or nil
end

-- Combine 2 filter-defs, by summing the min/max fields if present. Only f2 may be Nil.
local function combine_filter_defs(f1, f2)
    if f2 then
        f1.min = minsum(f1.min, f2.min)
        f1.max = maxsum(f1.max, f2.max)
    end
    return f1
end

-- Builds a table of player's logistic request slots. (F1.1: LogisticParameters; F2.0: "filterDef" objects)
-- @param   playerLogisticPoint   LuaLogisticPoint for this player
-- @return table of {item_name, quality_id, min, max} objects, keyed by prototype.item_name (AND quality?)
local function find_player_logistic_requests(playerLogisticPoint)
    local requests = {}

    for sectionIdx = 1, playerLogisticPoint.sections_count do
        local section = playerLogisticPoint.sections[sectionIdx]    -- LuaLogisticSection
        if section.active then
            for filterIdx = 1, section.filters_count do
                local f = section.filters[filterIdx]                -- LogisticFilter
                if f.value then
                    -- must aggregate over potentially multiple sections, and I think differentiate on quality (TODO)
                    local filterDef = { item_name = f.value.name,
                                        quality_id = f.value.quality,
                                        min = f.min,
                                        max = f.max }
                    requests[filterDef.item_name] = combine_filter_defs(filterDef, requests[filterDef.item_name])
                end
            end
        end
    end
    return requests
end

-- Iterates the supplied inventory and creates a map by item, identifying their slots by index and breaking them down by a) filtered b) healthy vs unhealthy
-- @param   main_inv   the player's main inventory
-- @param   requests   the current logistic requests from find_player_logistic_requests, keyed by item_name
-- @return the main inventory stack details, keyed by item-name (FIXME quality?)
local function gather_inventory_details_by_item(main_inv, requests)
    local item_stacks = {}

    for slot_index = 1, #main_inv do
        local stack = main_inv[slot_index]              -- LuaItemStack
        local filter = main_inv.get_filter(slot_index)  -- ItemFilter

        if (stack and stack.valid_for_read) or filter then
            local item_name, item_count
            if stack.valid_for_read then
                item_name = stack.name
                item_count = stack.count
            else
                item_name = filter
                item_count = 0
            end

            local item = prototypes.item[item_name]
            if item and item.stackable then
                local item_stack_details = item_stacks[item_name]
                if not item_stack_details then
                    local req = requests[item_name]
                    item_stack_details = { item_name = item_name, item = item, total_count = main_inv.get_item_count(item_name),
                                           stacks_by_index = {}, -- every stack slot for this item is collected here, except for empty filter slots which don't have one
                                           healthy_slots = {}, unhealthy_slots = {}, filter_slots = {},
                                           healthy_slot_count = 0, unhealthy_slot_count = 0, filter_slot_count = 0,
                                           req_min = (req and req.min or Nil), req_max = (req and req.max or Nil) }
                    item_stacks[item_name] = item_stack_details
                end

                item_stack_details.stacks_by_index[slot_index] = stack;
                if stack.valid_for_read then
                    if stack.health == 1 then
                        item_stack_details.healthy_slots[slot_index] = slot_index
                        item_stack_details.healthy_slot_count = item_stack_details.healthy_slot_count + 1
                    else
                        item_stack_details.unhealthy_slots[slot_index] = slot_index
                        item_stack_details.unhealthy_slot_count = item_stack_details.unhealthy_slot_count + 1
                    end
                end
                if filter then
                    item_stack_details.filter_slots[slot_index] = slot_index
                    item_stack_details.filter_slot_count = item_stack_details.filter_slot_count + 1
                end
            end
        end
    end
    return item_stacks
end

local function sortPairs(t, order)
    -- collect the keys
    local keys = {}
    for k in pairs(t) do
        keys[#keys + 1] = k
    end

    -- if order function given, sort by it by passing the table and keys a, b, otherwise just sort the keys
    if order then
        table.sort(keys, function(a, b)
            return order(t, a, b)
        end)
    else
        table.sort(keys)
    end

    -- return the iterator function
    local i = 0
    return function()
        i = i + 1
        if keys[i] then
            return keys[i], t[keys[i]]
        end
    end
end

local function reversePairs(t)
    return sortPairs(t, function(t, a, b)
        return a > b
    end)
end


-- Utility function for tidy_stacks: packs as many stacks from the slots_to_check into the indicated slot.
-- eg         compactStacks(details.healthy_slots, details.filter_slots, details.stacks_by_index, details.item.stack_size)
--
-- @param slots_to_check        the set of 'stacks' slot-indexes to scan, checked in right-to-left order. Note, any stacks that are fully transferred are removed from the set.
-- @param exclusions            stack ids to exclude from scan/compaction, eg filter slots
-- @param stacks                all inventory's LuaItemStacks occupied by this type of item
-- @param stack_size            the stack_size for this type of item
-- @returns number of stacks removed as a result of compaction
-- FIXME: "quality"?
local function compactStacks(slots_to_check, exclusions, stacks, stack_size)
    local count = 0
    for i, _ in pairs(slots_to_check) do
        if not exclusions[i] and stacks[i].count < stack_size then
            for j, _ in reversePairs(slots_to_check) do
                if i < j and not exclusions[j] then
                    if stacks[i].transfer_stack(stacks[j]) then
                        -- j'th slot has been fully transferred, so forget about it
                        slots_to_check[j] = Nil
                        count = count + 1
                    else
                        break
                    end
                end
            end
        end
    end
    return count
end

-- Utility function for tidy_stacks: packs as many stacks from the slots_to_check into the indicated slot, using LuaItemStack.transfer_stack.
-- eg compactStacksToSlot(filter_index, details.healthy_slots, details.filter_slots, details.stacks_by_index)
--
-- @param slot_to_fill_index    index in 'stacks' of the specific slot to be filled
-- @param slots_to_check        the set of 'stacks' slot-indexes to scan, checked in right-to-left order. Note, any stacks that are fully transferred are removed from the set.
-- @param filter_slots          the set of filter 'stacks' slot-indexes, skipping any filter slot with a lower index than the 'slot_to_fill_index'
-- @param stacks                the inventory's LuaItemStacks containing this item type
-- @returns number of stacks removed as a result of compaction
local function compactStacksToSlot(slot_to_fill_index, slots_to_check, filter_slots, stacks)
    local count = 0
    for i, _ in reversePairs(slots_to_check) do
        if i ~= slot_to_fill_index
                and (not filter_slots[i] or i > slot_to_fill_index) then
            if stacks[slot_to_fill_index].transfer_stack(stacks[i]) then
                -- i'th slot has been fully transferred, so forget about it
                slots_to_check[i] = Nil
                count = count + 1
            else
                break
            end
        end
    end
    return count
end

-- Performs a tidy-up of all the slots in main inventory, merging incomplete stacks to the left to free up space. This is essentially redundant if you have the
-- "Always keep Main Inventory sorted" enabled; however, this merges stacks without sorting or re-ordering. FIXME: "quality"?
local function tidy_stacks(item_stacks)
    for item_name, details in pairs(item_stacks) do
        -- merge filter slots
        for filter_index, _ in pairs(details.filter_slots) do
            -- if this filter slot is unhealthy, but there are healthy slots, then swap with one of them. Prioritise healthy items in filter slots.
            if details.stacks_by_index[filter_index].valid_for_read and details.unhealthy_slots[filter_index] then
                for healthy_index, _ in pairs(details.healthy_slots) do
                    -- only swap another filter slot if it's higher index, to avoid re-swapping, and to push stacks to the left
                    if healthy_index ~= filter_index
                            and (not details.filter_slots[healthy_index] or filter_index < healthy_index)
                            and details.stacks_by_index[filter_index].swap_stack(details.stacks_by_index[healthy_index]) then
                        -- update detail lists, as healthy and unhealthy slots have swapped
                        details.unhealthy_slots[filter_index], details.healthy_slots[healthy_index] = Nil, Nil
                        details.unhealthy_slots[healthy_index], details.healthy_slots[filter_index] = healthy_index, filter_index
                        break
                    end
                end
            end

            -- now transfer other healthy slots into this one - if they are filter slots, then only transfer if it's higher index (prioritize to the left).
            details.healthy_slot_count = details.healthy_slot_count - compactStacksToSlot(filter_index, details.healthy_slots, details.filter_slots, details.stacks_by_index)

            -- finally, if this filter stack is still empty or unhealthy, compact other unhealthy slots into it
            if not details.stacks_by_index[filter_index].valid_for_read or details.unhealthy_slots[filter_index] then
                details.unhealthy_slot_count = details.unhealthy_slot_count
                        - compactStacksToSlot(filter_index, details.unhealthy_slots, details.filter_slots, details.stacks_by_index)
            end
        end

        -- lastly, compact healthy and then unhealthy slots
        details.healthy_slot_count = details.healthy_slot_count - compactStacks(details.healthy_slots, details.filter_slots, details.stacks_by_index, details.item.stack_size)
        details.unhealthy_slot_count = details.unhealthy_slot_count - compactStacks(details.unhealthy_slots, details.filter_slots, details.stacks_by_index, details.item.stack_size)
    end
end

local function candidateOrder(t, a, b)
    return t[a].importance < t[b].importance
end

-- Builds a list of slot "candidates" for trimming
local function determine_candidate_actions(main_inv, item_stacks, player_settings)
    local stack_fullness_importance_boost = player_settings["stack-fullness-importance-boost"].value

    -- determine some updated stats: the abs min number of slots required, and the current number of slots above that ("excess" - these can reasonably be trimmed).
    -- plus, find the largest excess because high excessive slots are less important.
    local largest_excess_slots = 0
    for item_name, details in pairs(item_stacks) do
        -- no point in clearing slots with filters, or going below the request minimum, as it won't make more slots available.
        details.min_stacks_to_keep = math.max(details.filter_slot_count,
                math.ceil((details.req_min or 0) / details.item.stack_size), -- min stacks needed for req_min
                (details.req_min and details.req_min == 0 and 0) or 1 -- bare minimum: use "req_min explicitly set to zero" to mean "allow trimming last slot"
        )

        local excess_slots = details.healthy_slot_count + details.unhealthy_slot_count - details.min_stacks_to_keep
        if excess_slots > largest_excess_slots then
            largest_excess_slots = excess_slots
        end
        details.excess_slots = excess_slots
    end

    local candidates = {}
    for item_name, details in pairs(item_stacks) do
        local item = details.item

        local current_inventory_item_count = main_inv.get_item_count(item.name)

        -- scan all slots (from the right), assigning candidates for clearing, with "Importance". Importance 0 means lowest importance for *keeping*, ie trim it more enthusiastically.
        local this_item_candidates = {}

        -- handle unhealthy slots separately from healthy ones, they have much lower importance
        for i, _ in reversePairs(details.unhealthy_slots) do
            -- need to make sure that removing *unhealthy* items doesn't push us below the req_min, otherwise drones just re-deliver them!
            if not details.filter_slots[i] and (not details.req_min or current_inventory_item_count - details.stacks_by_index[i].count >= details.req_min) then
                this_item_candidates[#this_item_candidates + 1] = { item_name = item_name,
                                                                    item = item,
                                                                    importance = 4 * details.stacks_by_index[i].count / item.stack_size * stack_fullness_importance_boost,
                                                                    slot_index = i,
                                                                    stack_to_move = details.stacks_by_index[i] }
            end
        end

        -- ensures slots to the right have less importance than ones to the left, and item-types share the load of being trimmed
        local importanceEscalator = largest_excess_slots - details.excess_slots

        -- placeable items are more important than non-placeable, and raw materials and intermediates are much less important
        -- and logistic req_min implies player has expressed intent to maintain minimum, so less important to have excess. Min itself captured by min_stacks_to_keep.
        local subgroupBias = ((item.group.name == "intermediate-products" or item.subgroup.name == "raw-resource") and 0 or 2)
                + (item.place_result and 1 or 0)
                + (details.req_min and 0 or 2)

        for i, _ in reversePairs(details.healthy_slots) do
            if not details.filter_slots[i] then
                local importanceGrade = subgroupBias + importanceEscalator + (4 * details.stacks_by_index[i].count / item.stack_size * stack_fullness_importance_boost)

                this_item_candidates[#this_item_candidates + 1] = { item_name = item_name,
                                                                    item = item,
                                                                    importance = importanceGrade,
                                                                    slot_index = i,
                                                                    stack_to_move = details.stacks_by_index[i] }
                importanceEscalator = importanceEscalator + 1
            end
        end

        -- Append our candidates into the full list, trimmed to retain the min_stacks_to_keep, so only clear the excess.
        local max_stacks_to_clear = details.excess_slots
        local seen_already = {} -- only need one candidate per unique slot, it can only be trimmed once
        local slot_count = 0
        for i, c in sortPairs(this_item_candidates, candidateOrder) do
            if not seen_already[c.slot_index] and slot_count < max_stacks_to_clear then
                candidates[#candidates + 1] = c
                seen_already[c.slot_index] = true
                slot_count = slot_count + 1
            end
        end
    end
    return candidates
end

-- This is the main entry point for processing a specific player.
local function process_player(player_info)
    local p = player_info.player
    local player_settings = settings.get_player_settings(p.index)

    local main_inv = p.get_main_inventory()
    local logistics_trash = p.get_inventory(defines.inventory.character_trash)

    if not main_inv or not logistics_trash then
        deregister_player(p.index)
        return
    end

    -- if the player has disabled the trim, or has switched off logistics requests (get_requester_point=>LuaLogisticPoint)
    if not player_settings["trim-enabled"].value or not p.character.get_requester_point().enabled then
        return
    end

    local main_empty_stacks_count = main_inv.count_empty_stacks();
    local active_threshold = player_settings["inventory-slots-used-trimming-active-threshold"].value
    if main_empty_stacks_count >= #main_inv * (1 - active_threshold) then
        -- inventory is too empty to need trimming
        return
    end

    local notification_flying_text_enabled = player_settings["notification-flying-text-enabled"].value

    -- load the personal logistic request setup
    local requests = find_player_logistic_requests(p.character.get_requester_point())
    --p.print("transport-belt: " .. serpent.block(requests["transport-belt"]))

    -- Gather main-inventory info, mapped by item-name. FIXME: "quality"?
    local item_stacks = gather_inventory_details_by_item(main_inv, requests);
    --p.print("stone: " .. serpent.block(item_stacks["stone"]))

    tidy_stacks(item_stacks)

    local candidates = determine_candidate_actions(main_inv, item_stacks, player_settings)

    local slot_keep_free_count = player_settings["inventory-slots-keep-free"].value
    local slot_keep_free_aggressively_count = player_settings["inventory-slots-aggressively-keep-free"].value

    -- perform the actual transfer from main inventory to trash, by iterating the removal candidates in increasing importance order
    local summaries = {}
    local free_slot_count = main_inv.count_empty_stacks()

    for _, removal_candidate in sortPairs(candidates, candidateOrder) do
        if free_slot_count >= slot_keep_free_count then
            -- lots of free slots - just do gentle trim
            aggressiveness_importance_threshold = 5
        elseif free_slot_count >= slot_keep_free_aggressively_count then
            -- we're into the free slot warning zone
            aggressiveness_importance_threshold = 10
        else
            -- do everything. Being nice didn't work.
            aggressiveness_importance_threshold = 10000
        end

        if removal_candidate.importance < aggressiveness_importance_threshold then
            local s = removal_candidate.stack_to_move
            local items_moved = logistics_trash.insert(s)
            if items_moved == s.count then
                s.clear()
                free_slot_count = free_slot_count + 1
            else
                s.count = s.count - items_moved
            end

            summary = summaries[removal_candidate.item_name] or { item_name = removal_candidate.item_name,
                                                                  item = removal_candidate.item,
                                                                  removed_item_count = 0,
                                                                  stacks_cleared_count = 0 }
            summary.removed_item_count = summary.removed_item_count + items_moved
            summary.stacks_cleared_count = summary.stacks_cleared_count + (s.valid_for_read and 1 or 0)
            summaries[removal_candidate.item_name] = summary
        end
    end

    if notification_flying_text_enabled then
        local count = 0
        for _, summary in pairs(summaries) do
            if summary.removed_item_count > 0 then
                p.create_local_flying_text { text = { "itrim.notification-flying-text", -summary.removed_item_count, summary.item.localised_name, main_inv.get_item_count(summary.item_name) },
                                             position = { p.position.x, p.position.y - count },
                                             time_to_live = 180,
                                             speed = 40, -- check, this used to be 1, but in 2.0 that's really slow.
                                             color = { 128, 128, 192 } }
                count = count + 1
            end
        end
    end
end

-- This is the principle scan across registered players
local function check_monitored_players()
    if storage.player_info then
        for _, player_info in pairs(storage.player_info) do
            process_player(player_info)
        end
    end
end

----------------------------
-- Event Handler definitions
----------------------------

script.on_init(function()
    -- contains an entry for every registered player: only reg'd players get inventory scans.
    -- indexed by player_index. { player=game.get_player(idx) }
    storage.player_info = {}
    -- indexed by 'force.index',gives true or false
    storage.forces_researched = {}
end)

script.on_event(defines.events.on_player_joined_game, function(event)
    register_player(event.player_index)
end)

script.on_event(defines.events.on_player_left_game, function(event)
    deregister_player(event.player_index)
end)

script.on_event(defines.events.on_player_main_inventory_changed, function(event)
    register_player(event.player_index)
end)

local function show_trim_start_alert(player)
    player.print({ "itrim.schedule_period_ticks_changed", math.floor(settings.global["schedule-period-ticks"].value / 60) })
end

script.on_nth_tick(settings.global["schedule-period-ticks"].value, function(tickEvent)
    check_monitored_players()
    if not storage.schedule_period_ticks then
        storage.schedule_period_ticks = settings.global["schedule-period-ticks"].value
    end
end)

local function schedule_scanning()
    local new_schedule_period_ticks = settings.global["schedule-period-ticks"].value

    -- remove handler for previous tick schedule (on_nth_tick registers a handler for each tick count, so you must unset them)
    if storage.schedule_period_ticks then
        script.on_nth_tick(storage.schedule_period_ticks, Nil)
    end
    script.on_nth_tick(new_schedule_period_ticks, function(tickEvent)
        check_monitored_players()
    end)
    storage.schedule_period_ticks = new_schedule_period_ticks
end

script.on_event(defines.events.on_runtime_mod_setting_changed, function(event)
    -- note: schedule-period-ticks is a Map setting, not a Player setting: it affects everyone.
    if event.setting == "schedule-period-ticks" then
        schedule_scanning()

        for _, player_info in pairs(storage.player_info) do
            show_trim_start_alert(player_info.player)
        end
    end
end)

-- Trimming is enabled to all players in a Force, once relevant research is done.
script.on_event(defines.events.on_research_finished, function(event)
    if event.research.name == "inventory-trim-tech"
            or (not settings.startup["technology-item-required"].value and event.research.name == "logistic-robotics") then
        storage.forces_researched[event.research.force.index] = true
        schedule_scanning()
        for _, player in pairs(event.research.force.players) do
            if register_player(player.index) then
                show_trim_start_alert(player)
            end
        end
    end
end)
