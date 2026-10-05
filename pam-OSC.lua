-- pam-OSC. It allows to controll GrandMA3 with Midi Devices over Open Stage Controll and allows for Feedback from MA.
-- Copyright (C) 2024  xxpasixx
-- This program is free software: you can redistribute it and/or modify
-- it under the terms of the GNU General Public License as published by
-- the Free Software Foundation, either version 3 of the License, or
-- (at your option) any later version.
-- This program is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
-- GNU General Public License for more details.
-- You should have received a copy of the GNU General Public License
-- along with this program.  If not, see <https://www.gnu.org/licenses/>. 
local executorsToWatch = {}
local oldValues = {}
local oldButtonValues = {}
local oldColorValues = {}
local oldNameValues = {}
local oldKeyAssigned = {}
local oldMaKeyAssigned = {}
local olsMasterEnabledValue = {
    highlight = false,
    lowlight = false,
    solo = false,
    blind = false
}
local oldTimecodes = {}
local oldAttributeValues = ""
local oldFeatureGroup = ""
local oldCmdLineActive = nil
local oldSelectionKey = nil
local oldSelectionError = nil
local oldDeskLockedStatus = 0

local oscEntry = 2

-- Configure here, what executors you want to watch:
for i = 101, 122 do
    executorsToWatch[#executorsToWatch + 1] = i
end

for i = 201, 222 do
    executorsToWatch[#executorsToWatch + 1] = i
end

for i = 301, 322 do
    executorsToWatch[#executorsToWatch + 1] = i
end

for i = 401, 422 do
    executorsToWatch[#executorsToWatch + 1] = i
end

for i = 191, 198 do
    executorsToWatch[#executorsToWatch + 1] = i
end

for i = 291, 298 do
    executorsToWatch[#executorsToWatch + 1] = i
end

-- set the default Values
for _, number in ipairs(executorsToWatch) do
    oldValues[number] = "000"
    oldButtonValues[number] = false
    oldColorValues[number] = "0,0,0,0"
    oldNameValues[number] = ";"
end

-- the Speed to check executors
local tick = 1 / 10 -- 1/10
local resendTick = 0

local function getApereanceColor(sequence)
	local apper = sequence["APPEARANCE"]
	local returnText

	local function checkSquenceAppearance(apperH)
		if apperH ~= nil then
            if apperH['BACKR'] == 0 and apperH['BACKG'] == 0 and apperH['BACKB'] == 0 and apperH['BACKALPHA'] == 0 then
                returnText =  "255,255,255,255"
			else
				returnText =  apperH['BACKR'] .. "," ..  apperH['BACKG'] .. "," ..  apperH['BACKB'] .. "," .. apperH['BACKALPHA']
			end
		else
			returnText = "255,255,255,255"
		end
	end


    checkSquenceAppearance(apper)

	if (sequence.preferCueAppearance == true and sequence:CurrentChild()) then
        if (sequence:CurrentChild()[1].Appearance) then
            checkSquenceAppearance(sequence:CurrentChild()[1].Appearance)
        end
    end

  return returnText
end

local function getName(sequence)
    if sequence["CUENAME"] ~= nil then
        return sequence["NAME"] .. ";" .. sequence["CUENAME"]
    end
    return sequence["NAME"] .. ";"
end

-- Value of an attribute of a fixture in percent of its range, or "-" if it has none, and whether it's active
-- in the programmer: the programmer value, else the default of the fixture type. Uses the first step of the
-- programmer phaser (GetProgPhaser is undocumented).
-- Default value of a UI channel of a fixture in percent of its range (from its DMX channel, 24 bit), or nil
local function getDefaultValue(fixtureIndex, uiChannelIndex)
    for _, rtIndex in ipairs(GetRTChannels(fixtureIndex) or {}) do
        local rtChannel = GetRTChannel(rtIndex)
        if rtChannel ~= nil and rtChannel["ui_index_first"] == uiChannelIndex then
            local default = rtChannel["dmx_default"]
            if type(default) == "number" and default >= 0 and default <= 0xFFFFFF then
                return default / 0xFFFFFF * 100
            end
        end
    end
    return nil
end

-- Value of a UI channel of a fixture in percent of its range, or nil, and whether it's active in the programmer:
-- the programmer value, else the default of the fixture type
local function getChannelValue(fixtureIndex, uiChannelIndex)
    local ok, phaser = pcall(GetProgPhaser, uiChannelIndex, false)
    if ok and type(phaser) == "table" and (phaser.mask_active_value or 0) ~= 0 and type(phaser[1]) == "table" and
        type(phaser[1].absolute) == "number" then
        return phaser[1].absolute, true
    end
    return getDefaultValue(fixtureIndex, uiChannelIndex), false
end

local function getAttributeValue(fixtureIndex, attributeName)
    local attributeIndex = GetAttributeIndex(attributeName)
    if attributeIndex == nil then
        return "-", false
    end
    local uiChannelIndex = GetUIChannelIndex(fixtureIndex, attributeIndex)
    if uiChannelIndex == nil then
        return "-", false
    end
    local value, active = getChannelValue(fixtureIndex, uiChannelIndex)
    return value and string.format("%.1f", value) or "-", active
end

-- Values of the attributes (separated by ";") of the first selected fixture, and whether they're active in the
-- programmer ("1"/"0"), each separated by ";"
local function getAttributeValues(attributeList)
    local fixtureIndex = SelectionFirst()
    local values = {}
    local actives = {}
    for attributeName in string.gmatch(attributeList, "[^;]+") do
        local value, active = "-", false
        if fixtureIndex then
            value, active = getAttributeValue(fixtureIndex, attributeName)
        end
        values[#values + 1] = value
        actives[#actives + 1] = active and "1" or "0"
    end
    return table.concat(values, ";"), table.concat(actives, ";")
end

-- Names (separated by ";") of the attributes, out of the given ones, that at least one selected fixture has
local function getAvailableAttributes(attributeList)
    local attributes = {}
    for name in string.gmatch(attributeList, "[^;]+") do
        local index = GetAttributeIndex(name)
        if index ~= nil then
            attributes[#attributes + 1] = { name = name, index = index }
        end
    end

    local available = {}
    local fixtureIndex = SelectionFirst()
    while fixtureIndex ~= nil do
        for _, attribute in ipairs(attributes) do
            if not available[attribute.name] and GetUIChannelIndex(fixtureIndex, attribute.index) ~= nil then
                available[attribute.name] = true
            end
        end
        fixtureIndex = SelectionNext(fixtureIndex)
    end

    local names = {}
    for _, attribute in ipairs(attributes) do
        if available[attribute.name] then
            names[#names + 1] = attribute.name
        end
    end
    return table.concat(names, ";")
end

-- For each feature group (separated by ";"), up to 8 of its attributes that at least one selected fixture has,
-- as "Group:Attribute=Pretty name|..." separated by ";"
local function getGroupAttributes(groupList)
    local ok, definitions = pcall(function()
        return ShowData().LivePatch.AttributeDefinitions.Attributes:Children()
    end)
    if not ok then
        return ""
    end

    local found = {}
    local groups = {}
    for groupName in string.gmatch(groupList, "[^;]+") do
        found[groupName] = {}
        groups[#groups + 1] = groupName
    end

    for _, attribute in ipairs(definitions) do
        local inGroup, group = pcall(function()
            return attribute.Feature:Parent().name
        end)
        local name = tostring(attribute.name)
        local index = GetAttributeIndex(name)
        if inGroup and found[group] and #found[group] < 8 and index ~= nil then
            local fixtureIndex = SelectionFirst()
            while fixtureIndex ~= nil and GetUIChannelIndex(fixtureIndex, index) == nil do
                fixtureIndex = SelectionNext(fixtureIndex)
            end
            if fixtureIndex ~= nil then
                local hasPretty, pretty = pcall(function()
                    return attribute.Pretty
                end)
                pretty = (hasPretty and type(pretty) == "string" and pretty ~= "") and pretty or name
                -- These characters separate values here or in SendOSC
                found[group][#found[group] + 1] = name .. "=" .. pretty:gsub('[,;|="]', " ")
            end
        end
    end

    local result = {}
    for _, groupName in ipairs(groups) do
        result[#result + 1] = groupName .. ":" .. table.concat(found[groupName], "|")
    end
    return table.concat(result, ";")
end

-- Name of the feature group of the selected feature (e.g. "Position"), or ""
local function getSelectedFeatureGroup()
    local ok, name = pcall(function()
        return SelectedFeature():Parent().name
    end)
    return ok and name or ""
end

-- Text typed in the command line, without surrounding spaces
local function getCmdText()
    local ok, text = pcall(function()
        return CmdObj().cmdtext
    end)
    if not ok or type(text) ~= "string" then
        return ""
    end
    return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Clears the command line by pressing Esc in it: plugins can't edit its text directly
local function clearCmdLine()
    pcall(function()
        FindBestFocus(GetDisplayByIndex(1).CmdLineSection)
    end)
    pcall(function()
        Keyboard(1, "press", "Escape")
        Keyboard(1, "release", "Escape")
    end)
end

-- Whether an executor's key (prefix "KEY") or MA + key (prefix "MAKEY") has a function or custom command
local function isKeyAssigned(executor, prefix)
    local ok, assigned = pcall(function()
        local custom = executor[prefix .. "USECUSTOMCOMMAND"]
        if custom == true or custom == "Yes" then
            return (executor[prefix .. "COMMAND"] or "") ~= ""
        end
        return (executor[prefix .. "PRESS"] or "") ~= ""
    end)
    return ok and assigned or false
end

-- Executors MA shows on a page: its own, overridden by fixed executors of any page (shown on every page)
local function getVisibleExecutors(pageIndex)
    local visible = {}
    for _, executor in ipairs(DataPool().Pages[pageIndex]:Children()) do
        visible[executor.No] = executor
    end
    for _, page in ipairs(DataPool().Pages:Children()) do
        for _, executor in ipairs(page:Children()) do
            local ok, fixed = pcall(function()
                return executor.FIX
            end)
            if ok and (fixed == true or fixed == "Yes") then
                visible[executor.No] = executor
            end
        end
    end
    return visible
end

-- OSC goes over UDP with Lua's socket library to the destination of the OSC entry, so it doesn't fill MA's command
-- line history. Without the library or a UDP entry, it falls back to SendOSC commands.
local osc = nil
local oscUdp = nil
local oscDescription = nil

-- Reads the OSC entry's destination; called regularly, so changes in MA's network settings apply right away
local function updateOSC()
    local ok, result = pcall(function()
        local entry = ShowData().OSCBase[oscEntry]
        -- Lua reads the mode as a boolean, false being UDP (shown as "UDP" in MA)
        if (entry.MODE ~= false and tostring(entry.MODE):upper() ~= "UDP") or not string.pack then
            return nil
        end
        if not oscUdp then
            oscUdp = require("socket").udp()
            oscUdp:setoption("broadcast", true)
        end
        return { udp = oscUdp, ip = entry.DESTINATIONIP, port = tonumber(entry.PORT), prefix = entry.PREFIX or "" }
    end)
    osc = (ok and result and result.ip and result.port) and result or nil

    local description = osc and ("directly to " .. osc.ip .. ":" .. osc.port) or "with SendOSC commands"
    if description ~= oscDescription then
        oscDescription = description
        Printf("pam-osc: sending OSC " .. description)
    end
end

-- OSC string: null terminated, padded to 4 bytes
local function oscString(text)
    text = text .. "\0"
    return text .. string.rep("\0", (4 - #text % 4) % 4)
end

-- Sends an OSC message with one argument of type "i" (number), "s" (text), or "T"/"F" (none)
local function sendOSC(address, oscType, value)
    if osc then
        local types, data = oscType, ""
        if oscType == "i" then
            local number = tonumber(value) or 0
            if math.tointeger(number) then
                data = string.pack(">i4", math.tointeger(number))
            else
                types, data = "f", string.pack(">f", number)
            end
        elseif oscType == "s" then
            data = oscString(tostring(value))
        end
        local prefix = osc.prefix ~= "" and ("/" .. osc.prefix) or ""
        if osc.udp:sendto(oscString(prefix .. address) .. oscString("," .. types) .. data, osc.ip, osc.port) then
            return
        end
    end
    Cmd('SendOSC ' .. oscEntry .. ' "' .. address .. ',' .. oscType .. ',' .. (value ~= nil and tostring(value) or "") .. '"')
end

-- The module sends attribute changes as OSC to this UDP port instead of as commands, which would fill MA's command
-- line history. The plugin announces that it listens with "/PluginReady"; without that, the module uses commands.
local pluginPort = 9005
local listener = nil

local function openListener()
    local ok, udp = pcall(function()
        local udp = require("socket").udp()
        assert(udp:setsockname("*", pluginPort))
        udp:settimeout(0)
        return udp
    end)
    listener = ok and udp or nil
    if not ok then
        Printf("pam-osc: can't listen on port " .. pluginPort .. ": " .. tostring(udp))
    end
end

-- Reads an OSC string at a position; returns it and the position after its padding
local function readOSCString(data, position)
    local zero = data:find("\0", position, true)
    if not zero then
        return nil, #data + 1
    end
    return data:sub(position, zero - 1), zero + 1 + (3 - (zero - position) % 4)
end

-- Address and arguments (types i, f and s) of an OSC message
local function decodeOSC(data)
    local address, position = readOSCString(data, 1)
    local types
    types, position = readOSCString(data, position)
    local args = {}
    for oscType in (types or ""):sub(2):gmatch(".") do
        if oscType == "i" then
            args[#args + 1], position = string.unpack(">i4", data, position)
        elseif oscType == "f" then
            args[#args + 1], position = string.unpack(">f", data, position)
        elseif oscType == "s" then
            args[#args + 1], position = readOSCString(data, position)
        end
    end
    return address, args
end

local function clampPercent(value)
    return math.min(math.max(value, 0), 100)
end

-- Sets a UI channel's programmer value. With a phaser (several steps), the first step gets the value and the others
-- move along, so the effect keeps its shape and settings (speed, phase, fade ...).
local function setChannelValue(uiChannelIndex, value)
    local ok, phaser = pcall(GetProgPhaser, uiChannelIndex, false)
    if not ok or type(phaser) ~= "table" or (phaser.mask_active_value or 0) == 0 or type(phaser[1]) ~= "table" or
        type(phaser[1].absolute) ~= "number" then
        -- SetProgPhaserValue doesn't change anything; SetProgPhaser does
        SetProgPhaser(uiChannelIndex, { { absolute = clampPercent(value) } })
        return
    end

    local shift = value - phaser[1].absolute
    local newPhaser = {}
    for _, key in ipairs({ "abs_preset", "rel_preset", "fade", "delay", "speed", "phase", "measure", "gridpos" }) do
        newPhaser[key] = phaser[key]
    end
    for i, step in ipairs(phaser) do
        local newStep = {}
        for key, stepValue in pairs(step) do
            -- absolute_value is the DMX value of absolute, which changes
            if key ~= "absolute_value" then
                newStep[key] = stepValue
            end
        end
        if type(step.absolute) == "number" then
            newStep.absolute = clampPercent(step.absolute + shift)
        end
        newPhaser[i] = newStep
    end
    SetProgPhaser(uiChannelIndex, newPhaser)
end

-- Sets an attribute of all selected fixtures that have it; newValue(fixture, uiChannel) returns percent or nil
local function setAttribute(attributeName, newValue)
    local attributeIndex = GetAttributeIndex(attributeName)
    if attributeIndex == nil then
        return
    end
    local fixtureIndex = SelectionFirst()
    while fixtureIndex ~= nil do
        local uiChannelIndex = GetUIChannelIndex(fixtureIndex, attributeIndex)
        if uiChannelIndex ~= nil then
            local value = newValue(fixtureIndex, uiChannelIndex)
            if value ~= nil then
                setChannelValue(uiChannelIndex, value)
            end
        end
        fixtureIndex = SelectionNext(fixtureIndex)
    end
end

-- Handles the attribute changes the module sent since the last call
local function receiveFromModule()
    if not listener then
        return
    end
    while true do
        local data = listener:receive()
        if not data then
            return
        end
        local ok, err = pcall(function()
            local address, args = decodeOSC(data)
            local attribute, value = args[1], tonumber(args[2])
            if address == "/pam/attribute/relative" and value then
                setAttribute(attribute, function(fixture, channel)
                    local current = getChannelValue(fixture, channel)
                    return current and current + value
                end)
            elseif address == "/pam/attribute/absolute" and value then
                setAttribute(attribute, function()
                    return value
                end)
            elseif address == "/pam/attribute/default" then
                setAttribute(attribute, getDefaultValue)
            end
        end)
        if not ok then
            Printf("pam-osc: can't apply " .. tostring(err))
        end
    end
end

local function getMasterEnabled(masterName)
    if MasterPool()['Grand'][masterName]['FADERENABLED'] then
        return true
    else
        return false
    end
end

local function main()
    local automaticResendButtons = GetVar(GlobalVars(), "automaticResendButtons") or false
    local sendColors = GetVar(GlobalVars(), "sendColors") or false
    local sendNames = GetVar(GlobalVars(), "sendNames") or false
    local sendTimecode = GetVar(GlobalVars(), "sendTimecode") or false
    local fixedPageNr = GetVar(GlobalVars(), "fixedPageNr") or 0

    Printf("start pam OSC main()")
    updateOSC()
    openListener()
    local oscTick = 0
    Printf("automaticResendButtons: " .. (automaticResendButtons and "true" or "false"))
    Printf("sendColors: " .. (sendColors and "true" or "false"))
    Printf("sendNames: " .. (sendNames and "true" or "false"))
    Printf("sendTimecode: " .. (sendTimecode and "true" or "false"))
    Printf("fixedPageNr: " .. fixedPageNr)

    local destPage = 1
    local forceReload = true
    local forceReloadButtons = false

    if GetVar(GlobalVars(), "opdateOSC") ~= nil then
        SetVar(GlobalVars(), "opdateOSC", not GetVar(GlobalVars(), "opdateOSC"))
    else
        SetVar(GlobalVars(), "opdateOSC", true)
    end

    while (GetVar(GlobalVars(), "opdateOSC")) do
        oscTick = oscTick + 1
        if oscTick >= 10 then
            oscTick = 0
            updateOSC()
            -- Only over direct OSC: as SendOSC command, this would fill the command line history
            if listener and osc then
                sendOSC("/PluginReady", "i", pluginPort)
            end
        end

        local currentDeskLocked = DeskLocked()
        if currentDeskLocked ~= oldDeskLockedStatus then
            oldDeskLockedStatus = currentDeskLocked
            forceReload = true
        end
        
        if GetVar(GlobalVars(), "forceReload") == true then
            forceReload = true
            automaticResendButtons = GetVar(GlobalVars(), "automaticResendButtons") or false
            sendColors = GetVar(GlobalVars(), "sendColors") or false
            sendNames = GetVar(GlobalVars(), "sendNames") or false
            sendTimecode = GetVar(GlobalVars(), "sendTimecode") or false
            fixedPageNr = GetVar(GlobalVars(), "fixedPageNr") or 0
            SetVar(GlobalVars(), "forceReload", false)
        end

        if forceReload == true then
            sendOSC("/updatePage/current", "i", destPage)
            sendOSC("/status/deskLocked", currentDeskLocked and "T" or "F")
        end

        if automaticResendButtons then
            resendTick = resendTick + 1
        end
        if resendTick >= 15 then
            forceReloadButtons = true
            resendTick = 0
        end

        -- Check Master Enabled Values
        for masterKey, masterValue in pairs(olsMasterEnabledValue) do
            local currValue = getMasterEnabled(masterKey)
            if currValue ~= masterValue then
                sendOSC("/masterEnabled/" .. masterKey, "i", currValue and 1 or 0)
                olsMasterEnabledValue[masterKey] = currValue
            end
        end

        -- Check Page
        local myPage = CurrentExecPage()
        if fixedPageNr ~= nil and tostring(fixedPageNr) ~= "" and tonumber(fixedPageNr) and tonumber(fixedPageNr) ~= 0 then
            local Pages = DataPool().Pages
            local FixedPageRef = tonumber(fixedPageNr)

            if Pages[FixedPageRef] then
            myPage = Pages[FixedPageRef]
            end
        end

        if myPage.index ~= destPage then
            destPage = myPage.index
            for maKey, maValue in pairs(oldValues) do
                oldValues[maKey] = 000
            end
            for maKey, maValue in pairs(oldButtonValues) do
                oldButtonValues[maKey] = false
            end
            forceReload = true
            sendOSC("/updatePage/current", "i", destPage)
        end

        -- Get all Executors shown on the page, fixed ones included
        local executors = getVisibleExecutors(destPage)

        for listKey, listValue in pairs(executorsToWatch) do
            local faderValue = 0
            local buttonValue = false
            local colorValue = "0,0,0,0"
            local nameValue = ";"
            local keyAssigned = false
            local maKeyAssigned = false
            local isFlash = false

            -- Set Fader & button Values
            for maKey, maValue in pairs(executors) do
                if maValue.No == listValue then
                    keyAssigned = isKeyAssigned(maValue, "KEY")
                    maKeyAssigned = isKeyAssigned(maValue, "MAKEY")
                    local faderOptions = {}
                    faderOptions.value = faderEnd
                    faderOptions.token = "FaderMaster"
                    faderOptions.faderDisabled = false

                    faderValue = maValue:GetFader(faderOptions)
                    isFlash = maValue.KEY == "Flash"

                    local myobject = maValue.Object
                    if myobject ~= nil then
                        -- IsRunningPlayback replaces the deprecated HasActivePlayback, which older versions only have
                        local ok, running = pcall(function() return myobject:IsRunningPlayback() end)
                        if not ok then
                            running = myobject:HasActivePlayback()
                        end
                        buttonValue = running and true or false
                        if sendColors then
                            colorValue = getApereanceColor(myobject)
                        end
                        if sendNames then
                            nameValue = getName(myobject)
                        end
                    end

                end
            end

            -- Send Fader Value
            if (oldValues[listKey] ~= faderValue and not (isFlash and buttonValue and faderValue == 100)) or forceReload then
                hasFaderUpdated = true
                oldValues[listKey] = faderValue
                sendOSC("/Page" .. destPage .. "/Fader" .. listValue, "i", faderValue * 1.27)
            end

            -- Send Button Value
            if oldButtonValues[listKey] ~= buttonValue or forceReload or forceReloadButtons then
                oldButtonValues[listKey] = buttonValue
                sendOSC("/Page" .. destPage .. "/Button" .. listValue, "s", buttonValue and "On" or "Off")
            end

            -- Send Color Value
            if sendColors and (oldColorValues[listKey] ~= colorValue or forceReload) then
                oldColorValues[listKey] = colorValue
                local newValue = string.gsub(colorValue, ",", ";")
                sendOSC("/Page" .. destPage .. "/Color" .. listValue, "s", newValue)
            end

            -- Send whether the key and MA + key have a function
            if oldKeyAssigned[listKey] ~= keyAssigned or forceReload then
                oldKeyAssigned[listKey] = keyAssigned
                sendOSC("/Page" .. destPage .. "/KeyFn" .. listValue, "i", keyAssigned and 1 or 0)
            end
            if oldMaKeyAssigned[listKey] ~= maKeyAssigned or forceReload then
                oldMaKeyAssigned[listKey] = maKeyAssigned
                sendOSC("/Page" .. destPage .. "/MaKeyFn" .. listValue, "i", maKeyAssigned and 1 or 0)
            end

            -- Send Name Value
            if sendNames and (oldNameValues[listKey] ~= nameValue or forceReload) then
                oldNameValues[listKey] = nameValue
                sendOSC("/Page" .. destPage .. "/Name" .. listValue, "s", nameValue)
            end
        end
        
        -- Send Timecode
        if sendTimecode then
            local slots = Root().TimecodeSlots
                
            for _, slot in pairs(slots:Children()) do
                local time = slot.timestring
                
                if oldTimecodes[slot.no] ~= time or oldTimecodes[slot.no] == nil or forceReload == true then
                    oldTimecodes[slot.no] = time
                        
                    sendOSC("/Timecode" .. slot.no, "s", time)
                end
            end
        end
        
        -- Tell the module whether a command is being typed, so it sends executor keys here instead of to the
        -- playback; complete the command with such a key (set with SetGlobalVariable "pamOscKey" "page.exec")
        local cmdText = getCmdText()
        local cmdLineActive = cmdText ~= ""
        if cmdLineActive ~= oldCmdLineActive or forceReload then
            oldCmdLineActive = cmdLineActive
            sendOSC("/CmdLine", "i", cmdLineActive and 1 or 0)
        end
        local key = GetVar(GlobalVars(), "pamOscKey") or ""
        if key ~= "" then
            SetVar(GlobalVars(), "pamOscKey", "")
            if cmdLineActive then
                clearCmdLine()
                Cmd(cmdText .. " Page " .. key)
            end
        end

        -- Selection dependent reports for the module's attribute mode. They run protected: an error there is
        -- printed once and must not stop the page, button and fader feedback above.
        local selectionOk, selectionError = pcall(function()
        -- When the selection changes, send which of the module's encoder page attributes (set with
        -- SetGlobalVariable "pamOscPageAttributes") the selected fixtures have, and their attributes in the feature
        -- groups of pages that take them from MA ("pamOscGroupAttributes"). Lists start with ";" as they may be empty.
        local pageAttributes = GetVar(GlobalVars(), "pamOscPageAttributes") or ""
        local groupAttributes = GetVar(GlobalVars(), "pamOscGroupAttributes") or ""
        -- The extra parentheses turn "no value" (returned without a selection) into nil for tostring
        local selectionKey = pageAttributes .. "|" .. groupAttributes .. "|" .. tostring((SelectionCount())) .. "|" ..
                                 tostring((SelectionFirst()))
        if selectionKey ~= oldSelectionKey or forceReload then
            oldSelectionKey = selectionKey
            if pageAttributes ~= "" then
                sendOSC("/AttributesAvailable", "s", ";" .. getAvailableAttributes(pageAttributes))
            end
            if groupAttributes ~= "" then
                sendOSC("/GroupAttributes", "s", ";" .. getGroupAttributes(groupAttributes))
            end
        end

        -- Send the selected feature group
        local featureGroup = getSelectedFeatureGroup()
        if featureGroup ~= "" and (featureGroup ~= oldFeatureGroup or forceReload) then
            oldFeatureGroup = featureGroup
            sendOSC("/FeatureGroup", "s", featureGroup)
        end

        -- Send the attribute values the pam-osc module asks for (set with SetGlobalVariable "pamOscAttributes")
        local attributeList = GetVar(GlobalVars(), "pamOscAttributes") or ""
        if attributeList ~= "" then
            local values, actives = getAttributeValues(attributeList)
            if attributeList .. "|" .. values .. "|" .. actives ~= oldAttributeValues or forceReload then
                oldAttributeValues = attributeList .. "|" .. values .. "|" .. actives
                sendOSC("/Attributes", "s", values)
                sendOSC("/AttributesActive", "s", actives)
            end
        else
            oldAttributeValues = ""
        end
        end)
        if not selectionOk and selectionError ~= oldSelectionError then
            Printf("pam-osc: attribute feedback failed: " .. tostring(selectionError))
        end
        oldSelectionError = not selectionOk and selectionError or nil

        forceReload = false
        forceReloadButtons = false

        -- delay
        -- Apply the module's attribute changes more often than the rest is updated
        for _ = 1, 5 do
            receiveFromModule()
            coroutine.yield(tick / 5)
        end
    end

    -- Free the port for the next start
    if listener then
        listener:close()
        listener = nil
    end
end


return main
