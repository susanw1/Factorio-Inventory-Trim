--control.lua

-- registers a new player for inventory monitoring, if player a) not already registered, b) exists, c) is a character, d) has a main inventory.
-- @returns true if player added; false otherwise
local function register_player(player_index)
    if global.player_info[player_index] then
        return false        -- already registered
    end

    local p = game.get_player(player_index)
    if not (p and p.character and p.get_main_inventory()) then
        return false        -- invalid candidate for trimming
    end

    global.player_info[player_index] = { player = p, calls = 0 }
    return true
end

-- De-registers a player from inventory monitoring. They might have left, or we can't find anything more to do.
-- We'll re-register them if their inventory changes.
local function deregister_player(player_index)
    global.player_info[player_index] = nil
end

local function find_player_logistic_requests(player)
    local requests = {}
    for slot_index = 1, player.character.request_slot_count do
        local slot = player.get_personal_logistic_slot(slot_index)
        if slot.name then
            requests[slot.name] = slot
        end
    end
    return requests
end

-- iterates the supplied inventory and creates a map by item, identifying their slots by index and breaking them down by a) filtered b) healthy vs unhealthy
local function gather_inventory_details_by_item(main_inv, requests)
    local item_stacks = {}

    for slot_index = 1, #main_inv do
        local stack = main_inv[slot_index]
        local filter = main_inv.get_filter(slot_index)

        if (stack and stack.valid_for_read) or filter then
            local item_name, item_count
            if stack.valid_for_read then
                item_name = stack.name
                item_count = stack.count
            else
                item_name = filter
                item_count = 0
            end

            if slot_index % 2 == 0 then
                --game.print("main_inv slot[" .. slot_index .. "] has item_name=" .. item_name .. "(" .. item_count .. ")/h=" .. (stack.valid_for_read and stack.health or "-") .. " (filter=" .. tostring(filter) .. ")")
            end

            local item = game.item_prototypes[item_name]
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

-- Packs as many stacks from the slots_to_check into the indicated slot.
--
-- @param slot_to_fill_index index of the slot to be filled
-- @param slots_to_check the set of stacks to scan (right-to-left). Note, any stacks that are fully transferred are removed from the set1
-- @param filter_slots the set of filter slots, ignore any filter slot with a lower index
-- @param stacks the stacks occupied by this item's stacks
local function compactStacksToSlot(slot_to_fill_index, slots_to_check, filter_slots, stacks)
    local count = 0
    for i, _ in reversePairs(slots_to_check) do
        if i ~= slot_to_fill_index
                and (not filter_slots[i] or slot_to_fill_index < i) then
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
        local subgroupBias = ((item.subgroup.name == "intermediate-product" or item.subgroup.name == "raw-material") and 0 or 2)
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

local function process_player(player_info)
    local p = player_info.player
    local player_settings = settings.get_player_settings(p.index)

    local main_inv = p.get_main_inventory()
    local logistics_inv = p.get_inventory(defines.inventory.character_trash)

    if not main_inv or not logistics_inv then
        deregister_player(p.index)
        return
    end

    if not player_settings["trim-enabled"].value or not p.character_personal_logistic_requests_enabled then
        -- don't deregister player though - we want to trim when we're reactivated
        return
    end

    --game.print("Trimming inventory...")

    local main_empty_stacks_count = main_inv.count_empty_stacks();
    local active_threshold = player_settings["inventory-slots-used-trimming-active-threshold"].value
    if main_empty_stacks_count >= #main_inv * (1 - active_threshold) then
        -- inventory is too empty to need trimming
        deregister_player(p.index)
        return
    end

    local notification_flying_text_enabled = player_settings["notification-flying-text-enabled"].value

    -- load the personal logistic request setup
    local requests = find_player_logistic_requests(p)

    -- Gather main-inventory info, mapped by item-name.
    local item_stacks = gather_inventory_details_by_item(main_inv, requests);
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
            local items_moved = logistics_inv.insert(s)
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
                                             position = { p.position.x, p.position.y - count / 2 },
                                             time_to_live = 180,
                                             speed = 1,
                                             color = { 128, 128, 192 } }
                count = count + 1
            end
        end
    end
end

local function check_monitored_players()
    if global.player_info then
        for player_index, player_info in pairs(global.player_info) do
            player_info.calls = player_info.calls + 1
            process_player(player_info)
        end
    end
end

script.on_init(function()
    global.player_info = {}
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

script.on_event(defines.events.on_research_finished, function(event)
    if event.research.name == "inventory-trim-tech" then
        local schedule_period_ticks = settings.global["schedule-period-ticks"].value
        script.on_nth_tick(schedule_period_ticks, function(event)
            for _, p in pairs(game.players) do
                register_player(p.index)
            end
            check_monitored_players()
        end)
        game.print({ "itrim.schedule_period_ticks_changed", math.floor(schedule_period_ticks / 60) })
    end
end)
