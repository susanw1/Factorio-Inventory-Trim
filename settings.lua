
local settings = {
	{
		name = "trim-enabled",
		type = "bool-setting",
		setting_type = "runtime-per-user",
		default_value = true,
		order = "a",
	},
	{
		name = "stack-trimming-threshold",
		type = "double-setting",
		setting_type = "runtime-per-user",
		default_value = 0.2,
		minimum_value = 0,
		maximum_value = 1,
		order = "b1",
	},
	{
		name = "notification-flying-text-enabled",
		type = "bool-setting",
		setting_type = "runtime-per-user",
		default_value = true,
		order = "b2",
	},
}

data:extend(settings)
