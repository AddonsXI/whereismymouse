--[[
* Addons - Copyright (c) 2024 Ashita Development Team
* Contact: https://www.ashitaxi.com/
* Contact: https://discord.gg/Ashita
*
* This file is part of Ashita.
*
* Ashita is free software: you can redistribute it and/or modify
* it under the terms of the GNU General Public License as published by
* the Free Software Foundation, either version 3 of the License, or
* (at your option) any later version.
*
* Ashita is distributed in the hope that it will be useful,
* but WITHOUT ANY WARRANTY; without even the implied warranty of
* MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
* GNU General Public License for more details.
*
* You should have received a copy of the GNU General Public License
* along with Ashita.  If not, see <https://www.gnu.org/licenses/>.
--]]

addon.name      = 'whereismymouse';
addon.author    = 'AddonsXI';
addon.version   = '1.0.1';
addon.link      = 'https://github.com/AddonsXI';
addon.desc      = 'Shows a dot on the screen where the mouse is.';

-- Special thanks to atom0s for creating the Crosshair addon, which inspired this project and provided some of the code used here.

require('common');
local chat = require('chat');
local d3d8  = require('d3d8');
local imgui = require('imgui');
local settings = require('settings');

local pInterfaceHidden = ashita.memory.find('FFXiMain.dll', 0, '8B4424046A016A0050B9????????E8????????F6D81BC040C3', 0, 0);

local function GetInterfaceHidden()
    if (pInterfaceHidden ~= 0) then
        local ptr = ashita.memory.read_uint32(pInterfaceHidden + 10);
        if (ptr ~= 0 and ashita.memory.read_uint8(ptr + 0xB4) == 1) then
            return true;
        end
    end

    local index = AshitaCore:GetMemoryManager():GetParty():GetMemberTargetIndex(0);
    if (index == 0) then
        return true;
    end

    local flags = AshitaCore:GetMemoryManager():GetEntity():GetRenderFlags0(index);
    return (bit.band(flags, 0x200) ~= 0x200) or (bit.band(flags, 0x4000) ~= 0);
end

-- Default settings
local defaultConfig = T{
    dot = T{
        size = T{2},
        opacity = T{1.0},
        color = T{1.0, 1.0, 1.0, 1.0},  -- White (RGBA 0-1.0)
    },
    border = T{
        size = T{4},
        opacity = T{1.0},
        color = T{0.0, 0.0, 0.0, 1.0},  -- Black (RGBA 0-1.0)
    },
    autoHide = T{
        enabled = T{false},
        timeout = T{5},  -- Seconds of inactivity before hiding
    },
};

-- Addon variables..
local whereismymouse = T{
    enabled = true,
    configMenuOpen = false,
    settings = settings.load(defaultConfig),
    mouse_pos = T{
        x = 0,
        y = 0,
    },
    -- Wall clock milliseconds. os.clock is process CPU time in LuaJIT, so an idle
    -- timer built on it stretches exactly when the game is quiet, which is precisely
    -- when the mouse is not moving..
    lastMouseMoveTime = ashita.time.get_tick(),
};

--[[
* Updates the addon settings.
*
* @param {table} s - The new settings table to use for the addon settings. (Optional.)
--]]
local function update_settings(s)
    -- Update the settings table..
    if (s ~= nil) then
        whereismymouse.settings = s;
    end
    
    -- Save the current settings..
    settings.save();
end

--[[
* Registers a callback for the settings to monitor for changes.
--]]
settings.register('settings', 'settings_update', update_settings);

--[[
* Converts RGBA color (0-1.0) to ARGB hex format
* ImGui ColorEdit4 returns RGBA, but DirectX expects BGRA, so we swap R and B
* @param {table} rgba - Table with {r, g, b, a} values 0-1.0
* @return {number} ARGB color value (actually ABGR for DirectX)
--]]
local function rgbaToArgb(rgba, opacity)
    local a = math.floor(rgba[4] * (opacity or 1.0) * 255 + 0.5);
    local r = math.floor(rgba[1] * 255 + 0.5);
    local g = math.floor(rgba[2] * 255 + 0.5);
    local b = math.floor(rgba[3] * 255 + 0.5);
    -- DirectX uses BGRA format, so swap R and B
    return (a * 0x1000000) + (b * 0x10000) + (g * 0x100) + r;
end

--[[
* Renders the configuration menu
--]]
local function renderConfig()
    if not whereismymouse.configMenuOpen then
        return;
    end

    -- Set window position and size
    imgui.SetNextWindowPos({0, 0}, ImGuiCond_FirstUseEver);
    imgui.SetNextWindowSize({450, 320}, ImGuiCond_FirstUseEver);

    -- Use table reference for p_open so X button can modify it
    local p_open = T{true};
    
    -- Begin the configuration window
    if imgui.Begin('WhereIsMyMouse Config', p_open, bit.bor(ImGuiWindowFlags_NoSavedSettings, ImGuiWindowFlags_NoCollapse)) then
        -- Enable/Disable checkbox at the top
        local enabled_ref = T{whereismymouse.enabled};
        imgui.Checkbox('Enabled', enabled_ref);
        whereismymouse.enabled = enabled_ref[1];
        
        imgui.Spacing();
        imgui.Separator();
        imgui.Spacing();
        
        imgui.Text('Dot Settings');
        imgui.Separator();
        
        -- Sliders first
        if imgui.SliderInt('Dot Size', whereismymouse.settings.dot.size, 0, 50) then
            settings.save();
        end
        imgui.ShowHelp('Size of the dot in pixels.');

        imgui.Spacing();
        if imgui.SliderFloat('Dot Opacity', whereismymouse.settings.dot.opacity, 0.0, 1.0, '%.2f') then
            settings.save();
        end
        imgui.ShowHelp('Set to 0 for a hollow ring. The dot size still sets how big the ring is.');

        imgui.Spacing();
        if imgui.SliderInt('Border Thickness', whereismymouse.settings.border.size, 0, 50) then
            settings.save();
        end
        imgui.ShowHelp('Thickness of the border in pixels.');

        imgui.Spacing();
        if imgui.SliderFloat('Border Opacity', whereismymouse.settings.border.opacity, 0.0, 1.0, '%.2f') then
            settings.save();
        end
        imgui.ShowHelp('Opacity of the border.');
        
        imgui.Spacing();
        imgui.Spacing();
        
        -- Colors after sliders - side by side
        imgui.Text('Dot Color');
        imgui.SameLine(150);
        imgui.Text('Border Color');
        
        imgui.PushItemWidth(150);
        if imgui.ColorEdit4('##dotcolor', whereismymouse.settings.dot.color, ImGuiColorEditFlags_NoInputs) then
            settings.save();
        end
        imgui.PopItemWidth();
        imgui.ShowHelp('Color of the dot (RGBA).');
        
        imgui.SameLine(150);
        imgui.PushItemWidth(150);
        if imgui.ColorEdit4('##bordercolor', whereismymouse.settings.border.color, ImGuiColorEditFlags_NoInputs) then
            settings.save();
        end
        imgui.PopItemWidth();
        imgui.ShowHelp('Color of the border (RGBA).');
        
        imgui.Spacing();
        imgui.Separator();
        imgui.Spacing();
        
        -- Auto-hide settings
        local autoHideEnabled_ref = T{whereismymouse.settings.autoHide.enabled[1]};
        local oldValue = whereismymouse.settings.autoHide.enabled[1];
        imgui.Checkbox('Hide on Inactivity', autoHideEnabled_ref);
        whereismymouse.settings.autoHide.enabled[1] = autoHideEnabled_ref[1];
        if oldValue ~= whereismymouse.settings.autoHide.enabled[1] then
            settings.save();
        end
        imgui.ShowHelp('Hide the mouse dot after no mouse movement for the specified time.');
        
        -- Show timeout slider only if auto-hide is enabled
        if whereismymouse.settings.autoHide.enabled[1] then
            imgui.Spacing();
            if imgui.SliderInt('Hide After (seconds)', whereismymouse.settings.autoHide.timeout, 1, 120) then
                settings.save();
            end
            imgui.ShowHelp('Seconds of mouse inactivity before the dot is hidden.');
        end
        
        imgui.Spacing();
        imgui.Separator();
        imgui.Spacing();
        
        -- Buttons for resetting and closing
        if imgui.Button('  Reset Settings  ') then
            settings.reset();
            print(chat.header(addon.name):append(chat.message('Settings reset to defaults.')));
        end
        imgui.SameLine();
        if imgui.Button('  Close  ') then
            whereismymouse.configMenuOpen = false;
        end

        -- End the configuration window
        imgui.End();
    end
    
    -- Update configMenuOpen based on p_open (handles X button)
    if not p_open[1] then
        whereismymouse.configMenuOpen = false;
    end
end

--[[
* event: command
* desc : Event called when the addon is processing a command.
--]]
ashita.events.register('command', 'command_cb', function (e)
    -- Parse the command arguments..
    local args = e.command:args();
    if (#args == 0 or args[1] ~= '/whereismymouse') then
        return;
    end

    e.blocked = true;

    -- Handle: /whereismymouse or /whereismymouse config - Opens the config menu
    if (#args == 1 or (#args >= 2 and args[2]:any('config', 'settings'))) then
        whereismymouse.configMenuOpen = not whereismymouse.configMenuOpen;
        return;
    end

    -- Unhandled command - show help or do nothing
    return;
end);

--[[
* event: unload
* desc : Event called when the addon is being unloaded.
--]]
ashita.events.register('unload', 'unload_cb', function()
    settings.save();
end);

--[[
* event: d3d_present
* desc : Event called when the Direct3D device is presenting a scene.
--]]
ashita.events.register('d3d_present', 'present_cb', function ()
    -- Render config menu if open
    if whereismymouse.configMenuOpen then
        renderConfig();
    end

    if (whereismymouse.enabled == false) then return; end

    if (GetInterfaceHidden()) then return; end

    -- Check auto-hide feature
    local shouldHide = false;
    if whereismymouse.settings.autoHide.enabled[1] then
        local idleMs = ashita.time.get_tick() - whereismymouse.lastMouseMoveTime;
        if idleMs >= (whereismymouse.settings.autoHide.timeout[1] * 1000) then
            shouldHide = true;
        end
    end
    
    if shouldHide then return; end

    local res, vp = d3d8.get_device():GetViewport();
    if (res ~= 0 or vp == nil) then
        return;
    end

    local fg = imgui.GetForegroundDrawList();
    local mx = whereismymouse.mouse_pos.x;
    local my = whereismymouse.mouse_pos.y;

    -- Get settings values
    local dotSize = whereismymouse.settings.dot.size[1];
    local borderSize = whereismymouse.settings.border.size[1];
    local dotColor = rgbaToArgb(whereismymouse.settings.dot.color, whereismymouse.settings.dot.opacity[1]);
    local borderColor = rgbaToArgb(whereismymouse.settings.border.color, whereismymouse.settings.border.opacity[1]);

    local segments = 64;

    if (dotSize > 0) then
        fg:AddCircleFilled({ mx, my }, dotSize, dotColor, segments);
    end

    if (borderSize > 0) then
        fg:AddCircle({ mx, my }, dotSize + borderSize / 2, borderColor, segments, borderSize);
    end
end);

--[[
* event: mouse
* desc : Event called when the addon is processing mouse input. (WNDPROC)
--]]
ashita.events.register('mouse', 'mouse_cb', function (e)
    if (e.message ~= 512) then return; end

    whereismymouse.mouse_pos.x = e.x;
    whereismymouse.mouse_pos.y = e.y;
    whereismymouse.lastMouseMoveTime = ashita.time.get_tick();
end);
