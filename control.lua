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

    local candidates = {}

    local contents = main_inv.get_contents()
    for item_name, item_count in pairs(contents) do
        local item = game.item_prototypes[item_name]

        local stack_excess = item_count % item.stack_size
        if item and item.stackable then
            -- never remove the last stack, and never go below any logistics request minimum
            local min_items_to_keep = item.stack_size
            if requests[item_name] then
                min_items_to_keep = math.max(min_items_to_keep, requests[item_name].min)
            end

            if item_count > min_items_to_keep
                    and stack_excess > 0 and stack_excess < item.stack_size * slot_lower_threshold then
                -- trim-type 0 (obvious case)
                candidates[item_name] = { excess = stack_excess, remaining = item_count - stack_excess, item = item, trim_type = 0 }
                --elseif
            end
        end
    end

    -- FIXME: sort candidates as appropriate here

    -- perform the actual transfer from main inventory to trash
    local count = 0
    for item_name, item_removal_info in pairs(candidates) do
        local items_to_move = main_inv.remove({ name = item_name, count = item_removal_info.excess })
        local items_moved = logistics_inv.insert({ name = item_name, count = items_to_move })

        -- if for some reason not all items were trashed (eg trash full), then attempt to restore them to main_inv
        local items_restored
        if items_moved < items_to_move then
            items_restored = main_inv.insert({ name = item_name, count = items_to_move - items_moved })
        else
            items_restored = 0
        end

        if notification_flying_text_enabled then
            p.create_local_flying_text { text = { "itrim.notification-flying-text", -items_moved, item_removal_info.item.localised_name, item_removal_info.remaining + items_restored },
                                         position = { p.position.x, p.position.y - count * 1 },
                                         time_to_live = 180,
                                         color = { 128, 128, 192 } }
        end
        count = count + 1
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
