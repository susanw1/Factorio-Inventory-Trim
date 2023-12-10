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
                                           healthy_slot_count = 0, unhealthy_slot_count = 0,
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
                end
            end
        end
    end
    return item_stacks
end

local function pairsByKeys (t, f)
    local a = {}
    for n in pairs(t) do
        table.insert(a, n)
    end
    table.sort(a, f)
    local i = 0      -- iterator variable
    local iter = function()
        -- iterator function
        i = i + 1
        if a[i] == nil then
            return nil
        else
            return a[i], t[a[i]]
        end
    end
    return iter
end

local function reversePairs(t)
    return pairsByKeys(t, function(a, b)
        return a > b
    end)
end

local function compactStacks(set1, count, exclusions, stacks, stack_size)
    for i, _ in pairs(set1) do
        if not exclusions[i] and stacks[i].count < stack_size then
            for j, _ in reversePairs(set1) do
                if i < j and not exclusions[j] then
                    if stacks[i].transfer_stack(stacks[j]) then
                        set1[j] = Nil
                        count = count - 1
                    else
                        break
                    end
                end
            end
        end
    end
    return count
end

local function check_and_tidy(player_info, item_stacks)
    local tidied = false
    for item_name, details in pairs(item_stacks) do
        local stack_size = details.item.stack_size

        -- merge filter slots
        for filter_index, _ in pairs(details.filter_slots) do
            game.print("Checking filter: " .. filter_index)
            -- if this filter slot is unhealthy, but there are healthy slots, then swap with one of them. Prioritise healthy items in filter slots.
            if details.stacks_by_index[filter_index].valid_for_read and details.unhealthy_slots[filter_index] then
                for healthy_index, _ in pairs(details.healthy_slots) do
                    game.print("Comparing (unhealthy) filter=" .. filter_index .. " to healthy=" .. healthy_index)
                    -- only swap another filter slot if it's higher index, to avoid re-swapping, and to push stacks to the left
                    if healthy_index ~= filter_index
                            and (not details.filter_slots[healthy_index] or filter_index < healthy_index)
                            and details.stacks_by_index[filter_index].swap_stack(details.stacks_by_index[healthy_index]) then
                        -- update detail lists, as healthy and unhealthy slots have swapped
                        details.unhealthy_slots[filter_index], details.healthy_slots[healthy_index] = Nil, Nil
                        details.unhealthy_slots[healthy_index], details.healthy_slots[filter_index] = healthy_index, filter_index
                        game.print("Swapped filter=" .. filter_index .. " to healthy=" .. healthy_index)
                        break
                    end
                end
            end

            -- now transfer other healthy slots into this one - if they are filter slots, then only transfer if it's higher index (prioritize to the left).
            for healthy_index, _ in reversePairs(details.healthy_slots) do
                if healthy_index ~= filter_index
                        and (not details.filter_slots[healthy_index] or filter_index < healthy_index)
                        and details.stacks_by_index[filter_index].transfer_stack(details.stacks_by_index[healthy_index])
                        and not details.filter_slots[healthy_index] then
                    -- healthy_index slot has been fully transferred, so forget about it
                    details.healthy_slots[healthy_index] = Nil
                    details.healthy_slot_count = details.healthy_slot_count - 1
                end
            end

            -- finally, if this filter stack is still empty or unhealthy, compact other unhealthy slots into it
            if not details.stacks_by_index[filter_index].valid_for_read or details.unhealthy_slots[filter_index] then
                for unhealthy_index, _ in reversePairs(details.unhealthy_slots) do
                    if unhealthy_index ~= filter_index
                            and (not details.filter_slots[unhealthy_index] or filter_index < unhealthy_index)
                            and details.stacks_by_index[filter_index].transfer_stack(details.stacks_by_index[unhealthy_index])
                            and not details.filter_slots[unhealthy_index] then
                        -- unhealthy_index slot has been fully transferred, so forget about it
                        details.unhealthy_slots[unhealthy_index] = Nil
                        details.unhealthy_slot_count = details.unhealthy_slot_count - 1
                    end
                end
            end
        end

        details.healthy_slot_count = compactStacks(details.healthy_slots, details.healthy_slot_count, details.filter_slots, details.stacks_by_index, details.item.stack_size)

        details.unhealthy_slot_count = compactStacks(details.unhealthy_slots, details.unhealthy_slot_count, details.filter_slots, details.stacks_by_index, details.item.stack_size)

        --for healthy_index, _ in pairs(details.healthy_slots) do
        --    if not details.filter_slots[healthy_index] and details.stacks_by_index[healthy_index].count < stack_size then
        --        for healthy_index2, _ in reversePairs(details.healthy_slots) do
        --            if healthy_index < healthy_index2 and not details.filter_slots[healthy_index2] then
        --                if details.stacks_by_index[healthy_index].transfer_stack(details.stacks_by_index[healthy_index2]) then
        --                    details.healthy_slots[healthy_index2] = Nil
        --                    details.healthy_slot_count = details.healthy_slot_count - 1
        --                else
        --                    break
        --                end
        --            end
        --        end
        --    end
        --end

        --for unhealthy_index, _ in pairs(details.unhealthy_slots) do
        --    if not details.filter_slots[unhealthy_index] and details.stacks_by_index[unhealthy_index].count < stack_size then
        --        for unhealthy_index2, _ in pairs(details.unhealthy_slots) do
        --            if unhealthy_index < unhealthy_index2 and not details.filter_slots[unhealthy_index2] then
        --                if details.stacks_by_index[unhealthy_index].transfer_stack(details.stacks_by_index[unhealthy_index2]) then
        --                    details.unhealthy_slots[unhealthy_index2] = Nil
        --                    details.unhealthy_slot_count = details.unhealthy_slot_count - 1
        --                else
        --                    break
        --                end
        --            end
        --        end
        --    end
        --end

    end
    return tidied
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

    game.print("main_inv slots: sz=" .. #main_inv .. ", free=" .. main_inv.count_empty_stacks())
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
    if check_and_tidy(player_info, item_stacks) then
        game.print("Tidied!")
    end

    --local candidates = {}
    --if item and item.stackable then
    --    local stack_excess = item_count % item.stack_size
    --    -- never remove the last stack, and never go below any logistics request minimum
    --    local min_items_to_keep = item.stack_size
    --    if requests[item_name] then
    --        min_items_to_keep = math.max(min_items_to_keep, requests[item_name].min)
    --    end
    --
    --    if item_count > min_items_to_keep
    --            and stack_excess > 0 and stack_excess < item.stack_size * slot_lower_threshold then
    --        -- trim-type 0 (obvious case)
    --        candidates[item_name] = { excess = stack_excess, remaining = item_count - stack_excess, item = item, trim_type = 0 }
    --        --elseif
    --    end
    --end

    -- FIXME: sort candidates as appropriate here

    -- perform the actual transfer from main inventory to trash
    --local count = 0
    --for item_name, item_removal_info in pairs(candidates) do
    --    local items_to_move = main_inv.remove({ name = item_name, count = item_removal_info.excess })
    --    local items_moved = logistics_inv.insert({ name = item_name, count = items_to_move })
    --
    --    -- if for some reason not all items were trashed (eg trash full), then attempt to restore them to main_inv
    --    local items_restored
    --    if items_moved < items_to_move then
    --        items_restored = main_inv.insert({ name = item_name, count = items_to_move - items_moved })
    --    else
    --        items_restored = 0
    --    end
    --
    --    if notification_flying_text_enabled then
    --        p.create_local_flying_text { text = { "itrim.notification-flying-text", -items_moved, item_removal_info.item.localised_name, item_removal_info.remaining + items_restored },
    --                                     position = { p.position.x, p.position.y - count * 1 },
    --                                     time_to_live = 180,
    --                                     color = { 128, 128, 192 } }
    --    end
    --    count = count + 1
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
