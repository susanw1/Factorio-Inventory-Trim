--data.lua

local tech = {
    {
        name = 'inventory-trim-tech',
        type = 'technology',

        --icon = '__Inventory-Trim__/sprite/itrim-technology.png',
        icon_size = 128,
        icons = {
            { icon = "__base__/graphics/technology/logistic-robotics.png", icon_size = 256, icon_mipmaps = 4, shift = { 15, 20 }, scale = 0.65 },
            { icon = "__base__/graphics/technology/toolbelt.png", icon_size = 256, icon_mipmaps = 4, tint = tint, shift = { -38, -58 }, scale = 0.4 }
        },
        prerequisites = { "logistic-robotics" },

        effects = { { type = 'nothing',
                      effect_description = { 'itrim.enable-inventory-autotrim' },
                    } },

        unit = {
            count = 50,
            ingredients = {
                { "automation-science-pack", 1 },
                { "logistic-science-pack", 1 },
            },
            time = 20,
        },
    },
}

if settings.startup["technology-item-required"].value then
    data:extend(tech)
end
