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

local function process_player(player_info)
    local p = player_info.player
    local player_settings = settings.get_player_settings(p.index)

    --game.print("Checking: " .. p.index .. " = " .. p.name .. "; calls=" .. player_info.calls .. ", logistics? "
    --        .. tostring(p.character_personal_logistic_requests_enabled) .. "; " .. tostring(player_settings["stack-trimming-threshold"].value))

    local trim_enabled = player_settings["trim-enabled"].value
    local main_inv = p.get_main_inventory()
    local logistics_inv = p.get_inventory(defines.inventory.character_trash)

    if not trim_enabled or not main_inv or not logistics_inv then
        deregister_player(p.index)
        return
    end

    game.print("Trimming inventory...")

    --game.print("main_inv slots: sz=" .. #main_inv .. ", free=" .. main_inv.count_empty_stacks())
    --game.print("logistics_inv slots: sz=" .. #logistics_inv .. ", free=" .. logistics_inv.count_empty_stacks())

    local main_empty_stacks_count = main_inv.count_empty_stacks();
    local active_threshold = player_settings["inventory-slots-used-trimming-active-threshold"].value
    if main_empty_stacks_count >= #main_inv * (1 - active_threshold) then
        -- inventory is too empty to bother with!
        deregister_player(p.index)
        return
    end

    local slot_lower_threshold = player_settings["stack-trimming-threshold"].value
    local notification_flying_text_enabled = player_settings["notification-flying-text-enabled"].value

    -- load the personal logistic request setup
    local requests = find_player_logistic_requests(p)

    -- Gather main-inventory info, mapped by item-name.
    local item_stacks = gather_inventory_details_by_item(main_inv, requests);
    tidy_stacks(item_stacks)

    local Priority = { LEVEL_0_ }

    local candidates = {}
    for item_name, details in pairs(item_stacks) do
        local item = details.item

        -- no point in clearing slots with filters, or going below the request minimum, as it won't make more slots available.
        local min_stacks_to_keep = details.filter_slot_count
        local request_stacks_count = math.ceil((details.req_min or 0) / item.stack_size)
        if request_stacks_count > min_stacks_to_keep then
            min_stacks_to_keep = request_stacks_count
        end

        -- scan all slots, assigning candidates for clearing, with Priorities. Priority 0 means highest priority for trimming (or lowest for keeping!).
        local this_item_candidates = {}
        for i, _ in pairs(details.unhealthy_slots) do
            if not details.filter_slots[i] then
                -- small unhealthy stack with no filter - priority 0
                if details.stacks_by_index[i].count < item.stack_size * slot_lower_threshold then
                    candidates[#candidates + 1] = { item_name = item_name, item = item, priority = 0, slot_index = i, stack_to_move = details.stacks_by_index[i] }
                end
                -- large unhealthy not-quite-full stack with no filter - priority 3
                if details.stacks_by_index[i].count < item.stack_size then
                    candidates[#candidates + 1] = { item_name = item_name, item = item, priority = 3, slot_index = i, stack_to_move = details.stacks_by_index[i] }
                end
            end
        end
        for i, _ in pairs(details.healthy_slots) do
            if not details.filter_slots[i] and details.stacks_by_index[i].count < item.stack_size * slot_lower_threshold then
                -- small healthy stack with no filter - priority 1
                candidates[#candidates + 1] = { item_name = item_name, item = item, priority = 1, slot_index = i, stack_to_move = details.stacks_by_index[i] }
            end
        end
    end

    -- FIXME: sort candidates as appropriate here


    -- perform the actual transfer from main inventory to trash
    local summaries = {}

    for _, removal_candidate in sortPairs(candidates, function(t, a, b)
        return t[a].priority < t[b].priority
    end) do
        if removal_candidate.priority <= 2 then
            local free_logistics_slot = logistics_inv.find_empty_stack() or logistics_inv.find_item_stack(removal_candidate.item_name)
            if free_logistics_slot then
                local s = removal_candidate.stack_to_move
                local initial_item_count = s.count

                -- note, on complete transfer, removal_candidate.stack_to_move is no longer valid_for_read
                local stack_emptied = free_logistics_slot.transfer_stack(s)
                game.print("Items moved: priority=" .. removal_candidate.priority .. " tried=" .. s.count .. " " .. removal_candidate.item.name ..
                        "; moved all?=" .. tostring(stack_emptied) .. " valid_for_read? " .. tostring(s.valid_for_read))

                summary = summaries[removal_candidate.item_name] or { item_name = removal_candidate.item_name,
                                                                      item = removal_candidate.item,
                                                                      removed_item_count = 0,
                                                                      stacks_cleared_count = 0 }
                summary.removed_item_count = summary.removed_item_count + initial_item_count - (s.valid_for_read and s.count or 0)
                summary.stacks_cleared_count = summary.stacks_cleared_count + (stack_emptied and 1 or 0)
                summaries[removal_candidate.item_name] = summary
            end
        end
    end

    if notification_flying_text_enabled then
        local count = 0
        for _, summary in pairs(summaries) do
            if summary.removed_item_count > 0 then
                p.create_local_flying_text { text = { "itrim.notification-flying-text", -summary.removed_item_count, summary.item.localised_name, main_inv.get_item_count(summary.item_name) },
                                             position = { p.position.x, p.position.y - count/2 },
                                             time_to_live = 180,
                                             speed = 1,
                                             color = { 128, 128, 192 } }
                count = count + 1
            end
        end
    end

    --local items_to_move = main_inv.remove(item_removal_info.stack)
    --local items_moved = logistics_inv.insert({ name = item_removal_info.item_name, count = items_to_move, health = item_removal_info.stack.health})
    ------ if for some reason not all items were trashed (eg trash full), then attempt to restore them to main_inv
    --local items_restored
    --if items_moved < items_to_move then
    --    items_restored = main_inv.insert({ name = item_removal_info.item_name, count = items_to_move - items_moved, item_removal_info.stack.health })
    --else
    --    items_restored = 0
    --end
    --
    --if notification_flying_text_enabled then
    --    p.create_local_flying_text { text = { "itrim.notification-flying-text", -items_moved, item_removal_info.stack.item.localised_name, item_removal_info.remaining + items_restored },
    --                                 position = { p.position.x, p.position.y - count * 1 },
    --                                 time_to_live = 180,
    --                                 color = { 128, 128, 192 } }
    --end

    --local items_to_move = main_inv.remove({ name = item_name, count = item_removal_info.excess })
    --local items_moved = logistics_inv.insert({ name = item_name, count = items_to_move })
    --
    ---- if for some reason not all items were trashed (eg trash full), then attempt to restore them to main_inv
    --local items_restored
    --if items_moved < items_to_move then
    --    items_restored = main_inv.insert({ name = item_name, count = items_to_move - items_moved })
    --else
    --    items_restored = 0
    --end
    --
    --if notification_flying_text_enabled then
    --    p.create_local_flying_text { text = { "itrim.notification-flying-text", -items_moved, item_removal_info.item.localised_name, item_removal_info.remaining + items_restored },
    --                                 position = { p.position.x, p.position.y - count * 1 },
    --                                 time_to_live = 180,
    --                                 color = { 128, 128, 192 } }
    --end
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

script.on_nth_tick(613, function(event)
    check_monitored_players()
end)



--local status = "multi-stack"
--local show = true
--if item_count < item.stack_size then
--    status = "single-stack"
--elseif item_count == item.stack_size then
--    status = "perfect-1";
--    show = false
--elseif stack_excess == 0 then
--    status = "perfect-N";
--    show = false
--elseif stack_excess > 0 and stack_excess < item.stack_size * slot_lower_threshold then
--    status = "trim=" .. tostring(stack_excess)
--end
--if item.place_result then
--    status = status .. ",placeable"
--end
--if requests[item_name] then
--    local r = requests[item_name]
--    status = status .. ",req:(min=" .. (r.min or "X") .. ",max=" .. (r.max or "X") .. ")"
--end
--
--if show then
--    -- game.print(item_name .. "; " .. status .. "/" .. item.stack_size .. ": (" .. item_count .. "), excess=" .. stack_excess)
--end
