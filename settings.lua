
local settings = {
	{
		name = "schedule-period-ticks",
		type = "int-setting",
		setting_type = "runtime-global",
		default_value = 613,
		minimum_value = 127,
		order = "a",
	},
	{
		name = "trim-enabled",
		type = "bool-setting",
		setting_type = "runtime-per-user",
		default_value = true,
		order = "a",
	},
	{
		name = "stack-fullness-importance-boost",
		type = "double-setting",
		setting_type = "runtime-per-user",
		default_value = 1.0,
		minimum_value = 0,
		maximum_value = 3,
		order = "b1",
	},
	{
		name = "notification-flying-text-enabled",
		type = "bool-setting",
		setting_type = "runtime-per-user",
		default_value = true,
		order = "b2",
	},
	{
		name = "inventory-slots-used-trimming-active-threshold",
		type = "double-setting",
		setting_type = "runtime-per-user",
		default_value = 0.6,
		minimum_value = 0,
		maximum_value = 1,
		order = "c",
	},
	{
		name = "inventory-slots-keep-free",
		type = "int-setting",
		setting_type = "runtime-per-user",
		default_value = 10,
		minimum_value = 0,
		maximum_value = 40,
		order = "c1",
	},
	{
		name = "inventory-slots-aggressively-keep-free",
		type = "int-setting",
		setting_type = "runtime-per-user",
		default_value = 2,
		minimum_value = 0,
		maximum_value = 20,
		order = "c2",
	},
	{
		-- not implemented yet.
		name = "pickup-margin",
		type = "double-setting",
		setting_type = "runtime-per-user",
		default_value = 0.1,
		minimum_value = 0,
		maximum_value = 0.4,
		hidden = true,
		order = "c4",
	},
	{
		-- not implemented - requires memory from previous passes, hmm.
		name = "hold-off-time-secs",
		type = "int-setting",
		setting_type = "runtime-per-user",
		default_value = 10,
		minimum_value = 0,
		hidden = true,
		order = "c2",
	},
}

data:extend(settings)
