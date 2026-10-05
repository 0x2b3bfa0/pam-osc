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
local function getAttributeValue(fixtureIndex, attributeName)
    local attributeIndex = GetAttributeIndex(attributeName)
    if attributeIndex == nil then
        return "-", false
    end
    local uiChannelIndex = GetUIChannelIndex(fixtureIndex, attributeIndex)
    if uiChannelIndex == nil then
        return "-", false
    end

    local ok, phaser = pcall(GetProgPhaser, uiChannelIndex, false)
    if ok and type(phaser) == "table" and (phaser.mask_active_value or 0) ~= 0 and type(phaser[1]) == "table" and
        type(phaser[1].absolute) == "number" then
        return string.format("%.1f", phaser[1].absolute), true
    end

    -- Not in the programmer: the default value of the DMX channel (24 bit)
    for _, rtIndex in ipairs(GetRTChannels(fixtureIndex) or {}) do
        local rtChannel = GetRTChannel(rtIndex)
        if rtChannel ~= nil and rtChannel["ui_index_first"] == uiChannelIndex then
            local default = rtChannel["dmx_default"]
            if type(default) == "number" and default >= 0 and default <= 0xFFFFFF then
                return string.format("%.1f", default / 0xFFFFFF * 100), false
            end
        end
    end
    return "-", false
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
            Cmd('SendOSC ' .. oscEntry .. ' "/updatePage/current,i,' .. destPage)
            Cmd('SendOSC ' .. oscEntry .. ' "/status/deskLocked,' .. (currentDeskLocked and "T," or "F,") .. '"')
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
                Cmd('SendOSC ' .. oscEntry .. ' "/masterEnabled/' .. masterKey .. ',i,' .. (currValue and 1 or 0))
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
            Cmd('SendOSC ' .. oscEntry .. ' "/updatePage/current,i,' .. destPage)
        end

        -- Get all Executors
        local executors = DataPool().Pages[destPage]:Children()

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
                Cmd('SendOSC ' .. oscEntry .. '  "/Page' .. destPage .. '/Fader' .. listValue .. ',i,' ..
                        (faderValue * 1.27) .. '"')
            end

            -- Send Button Value
            if oldButtonValues[listKey] ~= buttonValue or forceReload or forceReloadButtons then
                oldButtonValues[listKey] = buttonValue
                Cmd('SendOSC ' .. oscEntry .. '  "/Page' .. destPage .. '/Button' .. listValue .. ',s,' ..
                        (buttonValue and "On" or "Off") .. '"')
            end

            -- Send Color Value
            if sendColors and (oldColorValues[listKey] ~= colorValue or forceReload) then
                oldColorValues[listKey] = colorValue
                local newValue = string.gsub(colorValue, ",", ";")
                Cmd('SendOSC ' .. oscEntry .. '  "/Page' .. destPage .. '/Color' .. listValue .. ',s,' .. newValue ..
                        '"')
            end

            -- Send whether the key and MA + key have a function
            if oldKeyAssigned[listKey] ~= keyAssigned or forceReload then
                oldKeyAssigned[listKey] = keyAssigned
                Cmd('SendOSC ' .. oscEntry .. ' "/Page' .. destPage .. '/KeyFn' .. listValue .. ',i,' ..
                        (keyAssigned and 1 or 0) .. '"')
            end
            if oldMaKeyAssigned[listKey] ~= maKeyAssigned or forceReload then
                oldMaKeyAssigned[listKey] = maKeyAssigned
                Cmd('SendOSC ' .. oscEntry .. ' "/Page' .. destPage .. '/MaKeyFn' .. listValue .. ',i,' ..
                        (maKeyAssigned and 1 or 0) .. '"')
            end

            -- Send Name Value
            if sendNames and (oldNameValues[listKey] ~= nameValue or forceReload) then
                oldNameValues[listKey] = nameValue
                Cmd('SendOSC ' .. oscEntry .. '  "/Page' .. destPage .. '/Name' .. listValue .. ',s,' .. nameValue ..
                        '"')
            end
        end
        
        -- Send Timecode
        if sendTimecode then
            local slots = Root().TimecodeSlots
                
            for _, slot in pairs(slots:Children()) do
                local time = slot.timestring
                
                if oldTimecodes[slot.no] ~= time or oldTimecodes[slot.no] == nil or forceReload == true then
                    oldTimecodes[slot.no] = time
                        
                    Cmd('SendOSC ' .. oscEntry .. ' "/Timecode' .. slot.no .. ',s,' .. time .. '"')
                end
            end
        end
        
        -- Tell the module whether a command is being typed, so it sends executor keys here instead of to the
        -- playback; complete the command with such a key (set with SetGlobalVariable "pamOscKey" "page.exec")
        local cmdText = getCmdText()
        local cmdLineActive = cmdText ~= ""
        if cmdLineActive ~= oldCmdLineActive or forceReload then
            oldCmdLineActive = cmdLineActive
            Cmd('SendOSC ' .. oscEntry .. ' "/CmdLine,i,' .. (cmdLineActive and 1 or 0) .. '"')
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
        local selectionKey = pageAttributes .. "|" .. groupAttributes .. "|" .. tostring(SelectionCount()) .. "|" ..
                                 tostring(SelectionFirst())
        if selectionKey ~= oldSelectionKey or forceReload then
            oldSelectionKey = selectionKey
            if pageAttributes ~= "" then
                Cmd('SendOSC ' .. oscEntry .. ' "/AttributesAvailable,s,;' .. getAvailableAttributes(pageAttributes) .. '"')
            end
            if groupAttributes ~= "" then
                Cmd('SendOSC ' .. oscEntry .. ' "/GroupAttributes,s,;' .. getGroupAttributes(groupAttributes) .. '"')
            end
        end

        -- Send the selected feature group
        local featureGroup = getSelectedFeatureGroup()
        if featureGroup ~= "" and (featureGroup ~= oldFeatureGroup or forceReload) then
            oldFeatureGroup = featureGroup
            Cmd('SendOSC ' .. oscEntry .. ' "/FeatureGroup,s,' .. featureGroup .. '"')
        end

        -- Send the attribute values the pam-osc module asks for (set with SetGlobalVariable "pamOscAttributes")
        local attributeList = GetVar(GlobalVars(), "pamOscAttributes") or ""
        if attributeList ~= "" then
            local values, actives = getAttributeValues(attributeList)
            if attributeList .. "|" .. values .. "|" .. actives ~= oldAttributeValues or forceReload then
                oldAttributeValues = attributeList .. "|" .. values .. "|" .. actives
                Cmd('SendOSC ' .. oscEntry .. ' "/Attributes,s,' .. values .. '"')
                Cmd('SendOSC ' .. oscEntry .. ' "/AttributesActive,s,' .. actives .. '"')
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
        coroutine.yield(tick)
    end

end


return main
