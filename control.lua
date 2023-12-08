--control.lua

script.on_init(function()
    global.player_info = {}
end)

-- registers a new player for inventory monitoring, if player a) not already registered, b) exists, c) is a character, d) has a main inventory.
-- @returns true if player added; false otherwise
local function register_player(pid)
    if global.player_info[pid] then
        return false        -- already registered
    end

    local p = game.get_player(pid)
    if not (p and p.character and p.get_main_inventory()) then
        return false        -- invalid candidate for trimming
    end

    global.player_info[pid] = { player = p, calls = 0 }
    game.print("Registered player: " .. pid)
    return true
end

-- De-registers a player from inventory monitoring. They might have left, or we can't find anything more to do.
-- We'll re-register them if their inventory changes.
local function deregister_player(pid)
    global.players[pid] = nil
    game.print("Deregistered player: " .. pid)
end

script.on_event(defines.events.on_player_joined_game, function(event)
    register_player(event.player_index)
end)
script.on_event(defines.events.on_player_left_game, function(event)
    deregister_player(event.player_index)
end)

local function check_monitored_players()
    if global.player_info then
        game.print "check_monitored_players"
        for pid, player_info in pairs(global.player_info) do
            player_info.calls = player_info.calls + 1

            local p = player_info.player
            game.print("Checking: " .. pid .. " = " .. p.name .. "; calls=" .. player_info.calls .. ", logistics? "
                    .. tostring(p.character_personal_logistic_requests_enabled))

            local main_inv = p.get_main_inventory()
            local logistics_inv = p.get_inventory(defines.inventory.character_trash)

            if main_inv and logistics_inv then
                game.print("main_inv slots: sz=" .. #main_inv .. ", free=" .. main_inv.count_empty_stacks())
                game.print("logistics_inv slots: sz=" .. #logistics_inv .. ", free=" .. logistics_inv.count_empty_stacks())

                local requests = {}
                for slot_index = 1, p.character.request_slot_count do
                    local slot = p.get_personal_logistic_slot(slot_index)
                    if slot.name then
                        requests[slot.name] = slot
                    end
                end
                game.print("request slots: sz=" .. #requests .. "; " .. p.character.request_slot_count)

                local contents = main_inv.get_contents()
                for item_name, item_count in pairs(contents) do
                    local item = game.item_prototypes[item_name]

                    local stack_excess = item_count % item.stack_size
                    local status = "multi-stack"
                    local show = true
                    if item and item.stackable then
                        if item_count < item.stack_size then
                            status = "single-stack"
                        elseif item_count == item.stack_size then
                            status = "perfect-1";
                            show = false
                        elseif stack_excess == 0 then
                            status = "perfect-N";
                            show = false
                        elseif stack_excess > 0 and stack_excess < item.stack_size * 0.2 then
                            status = "trim=" .. tostring(stack_excess)
                        end
                        if item.place_result then
                            status = status .. ",placeable"
                        end
                        if requests[item_name] then
                            local r = requests[item_name]
                            status = status .. ",req:(min=" .. (r.min or "X") .. ",max=" .. (r.max or "X") .. ")"
                        end
                        if show then
                            game.print(item_name .. "; " .. status .. "/" .. item.stack_size .. ": " .. item_count)
                        end
                    end
                end
            else
                deregister_player(pid)
            end
        end
    else
        game.print("global.player_info is null")
    end
end

script.on_nth_tick(601, check_monitored_players)

script.on_event(defines.events.on_player_main_inventory_changed, function(event)
    register_player(event.player_index)
    game.print("inventory changed: " .. event.player_index)
end
)

--[[
script.on_event(defines.events.on_player_changed_position,
  function(event)
    local player = game.get_player(event.player_index) -- get the player that moved            
    -- if they're wearing our armor
    if player.character and player.get_inventory(defines.inventory.character_armor).get_item_count("fire-armor") >= 1 then
       -- create the fire where they're standing
       player.surface.create_entity{name="fire-flame", position=player.position, force="neutral"} 
    end
  end
)
--]]

--[[ 
script.on_event(defines.events.on_tick, function(event) 
	game.print(event.tick.. ",") 
end)
--]]
