--control.lua

script.on_init(function()
	global.players = {}
end)

local function register_player(pid)
	global.players[pid] = game.get_player(pid)
	game.print("Registered player: " .. pid)
end

local function deregister_player(pid)
	global.players[pid] = nil
	game.print("Deregistered player: " .. pid)
end

script.on_event(defines.events.on_player_joined_game, function(event) register_player(event.player_index) end)
script.on_event(defines.events.on_player_left_game, function (event) deregister_player(event.player_index) end)


local function check_all_players()
	if global.players then
		game.print("players:")		
		for pid,player in pairs(global.players) do
			game.print("Checking: " .. pid .. " = " .. player.name)
			local main_inv = player.get_main_inventory()
			local logistics_inv = player.get_inventory(defines.inventory.character_trash)	

			if main_inv then
				game.print("main_inv slots: sz=" .. #main_inv .. ", free=" .. main_inv.count_empty_stacks())
				game.print("logistics_inv slots: sz=" .. #logistics_inv .. ", free=" .. logistics_inv.count_empty_stacks())				
				
				local contents = main_inv.get_contents()
				for item_name, item_count in pairs(contents) do
					if item_count == 1 then
						local item = game.item_prototypes[item_name]
						
						game.print(item_name .. "; " .. tostring(item.stackable) .. "/" .. item.stack_size .. ": " .. item_count)
					end
				end
			end
		end
	else
		game.print("global.players is null")
	end
end

script.on_nth_tick(1201, check_all_players)

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

