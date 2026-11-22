-- BaddiesControllerCombos.lua
-- Controller-only combo macro. Client-side Luau for an executor environment.
-- Layout and options follow the screen recording you gave me (Combos tab).
-- NOT run or tested here. See the closing status in the chat reply.

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local GuiService = game:GetService("GuiService")
local CoreGui = game:GetService("CoreGui")

----------------------------------------------------------------------
-- CONFIG: every non-code value lives here, with where it came from.
-- [video]  = read from your screen recording
-- [user]   = stated by you in chat
-- [assume] = my choice, not verified against the game
----------------------------------------------------------------------
local CONFIG = {
	ComboCount = 4,                 -- [video] Combo 1..4 sections (Combo 4 text, "Clear Combo 3")
	MaxSlotsPerCombo = 5,           -- [video] "Adds another tool slot ... (max 5)"
	MinSlotsPerCombo = 1,           -- [video] "keeps at least 1"
	DefaultDelayMs = 10,            -- [user] 0.01 s; [video] slider default shows 10
	DelayMinMs = 0,                 -- [video] "0 is fastest"
	DelayMaxMs = 500,               -- [assume] slider upper bound not visible
	DefaultHotbarKey = 5,           -- [video] "Combo Hotbar Key" shows 5
	HotbarKeyMin = 1,               -- [assume]
	HotbarKeyMax = 9,               -- [assume]
	DefaultBindings = { "DPadLeft", "DPadUp", "DPadRight", "None" }, -- [video] defaults; Combo 4 unbound
	DefaultEndClick = { true, false, false, false }, -- [video] Combo 1 shown ON; others [assume] off
	MenuToggleButton = "ButtonSelect", -- [assume] opens/closes the menu; B also closes it
	ActivateEachSlot = true,        -- [assume] equip tool, then left click, for every slot. The recording
	                                --          does not show what a slot does besides selecting the tool.
	PressHoldHeartbeats = 1,        -- [assume] frames a synthetic key or click stays down
	ToolNameMaxLength = 100,        -- [assume] sanity bound when loading a save
	SaveFile = "BaddiesControllerCombos.json", -- [assume] used only if the executor has writefile/readfile
	InstanceKey = "__BaddiesControllerCombos",   -- [assume] guards against loading twice
}

-- Buttons the Roblox gamepad API reports. Roblox normalizes Xbox, PlayStation, Switch and
-- generic pads onto these KeyCodes, and Gamepad1..Gamepad8 cover every connected pad.
local BINDABLE_BUTTONS = {
	"None",
	"DPadLeft", "DPadUp", "DPadRight", "DPadDown",
	"ButtonA", "ButtonB", "ButtonX", "ButtonY",
	"ButtonL1", "ButtonR1", "ButtonL2", "ButtonR2",
	"ButtonL3", "ButtonR3", "ButtonStart", "ButtonSelect",
}
local VALID_BUTTON = {}
for _, name in ipairs(BINDABLE_BUTTONS) do
	VALID_BUTTON[name] = true
end

local GAMEPAD_TYPES = {}
for i = 1, 8 do
	GAMEPAD_TYPES[Enum.UserInputType["Gamepad" .. i]] = true
end

local NUMBER_KEYCODES = {
	Enum.KeyCode.One, Enum.KeyCode.Two, Enum.KeyCode.Three, Enum.KeyCode.Four, Enum.KeyCode.Five,
	Enum.KeyCode.Six, Enum.KeyCode.Seven, Enum.KeyCode.Eight, Enum.KeyCode.Nine,
}

----------------------------------------------------------------------
-- Pure helpers (no game access)
----------------------------------------------------------------------
local function isFiniteNumber(v)
	return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

local function clampInt(v, lo, hi, fallback)
	if not isFiniteNumber(v) then
		return fallback
	end
	return math.clamp(math.floor(v + 0.5), lo, hi)
end

-- Returns the next/previous entry of `list` after `current`, skipping names in `skip`.
local function stepOption(list, current, dir, skip)
	local n = #list
	local idx = table.find(list, current) or 0
	for _ = 1, n do
		idx = ((idx - 1 + dir) % n) + 1
		local candidate = list[idx]
		if not (skip and skip[candidate]) then
			return candidate
		end
	end
	return current
end

local function defaultState()
	local state = {
		delayMs = CONFIG.DefaultDelayMs,
		hotbarKey = CONFIG.DefaultHotbarKey,
		combos = {},
	}
	for i = 1, CONFIG.ComboCount do
		state.combos[i] = {
			button = CONFIG.DefaultBindings[i] or "None",
			endClick = CONFIG.DefaultEndClick[i] == true,
			slots = { "" },
		}
	end
	return state
end

-- Validates a decoded save. Anything wrong falls back to the default for that field.
local function sanitizeState(raw)
	local state = defaultState()
	if type(raw) ~= "table" then
		return state
	end
	state.delayMs = clampInt(raw.delayMs, CONFIG.DelayMinMs, CONFIG.DelayMaxMs, state.delayMs)
	state.hotbarKey = clampInt(raw.hotbarKey, CONFIG.HotbarKeyMin, CONFIG.HotbarKeyMax, state.hotbarKey)
	if type(raw.combos) ~= "table" then
		return state
	end
	local usedButtons = {}
	for i = 1, CONFIG.ComboCount do
		local rc = raw.combos[i]
		local combo = state.combos[i]
		if type(rc) == "table" then
			if type(rc.button) == "string" and VALID_BUTTON[rc.button] then
				combo.button = rc.button
			end
			if type(rc.endClick) == "boolean" then
				combo.endClick = rc.endClick
			end
			if type(rc.slots) == "table" then
				local slots = {}
				for s = 1, math.min(#rc.slots, CONFIG.MaxSlotsPerCombo) do
					local name = rc.slots[s]
					if type(name) == "string" and #name <= CONFIG.ToolNameMaxLength then
						slots[s] = name
					else
						slots[s] = ""
					end
				end
				if #slots >= CONFIG.MinSlotsPerCombo then
					combo.slots = slots
				end
			end
		end
		if combo.button == CONFIG.MenuToggleButton then
			combo.button = "None"
		end
		if combo.button ~= "None" then
			if usedButtons[combo.button] then
				combo.button = "None"
			else
				usedButtons[combo.button] = true
			end
		end
	end
	return state
end

----------------------------------------------------------------------
-- Single-instance guard and cleanup (one path for reload and shutdown)
----------------------------------------------------------------------
local env = (typeof(getgenv) == "function" and getgenv()) or _G
if type(env[CONFIG.InstanceKey]) == "function" then
	pcall(env[CONFIG.InstanceKey])
end

local connections = {}
local gui = nil
local alive = true

local function destroy()
	alive = false
	for _, c in ipairs(connections) do
		pcall(function() c:Disconnect() end)
	end
	table.clear(connections)
	if gui then
		pcall(function() GuiService.SelectedObject = nil end)
		pcall(function() gui:Destroy() end)
		gui = nil
	end
	if env[CONFIG.InstanceKey] == destroy then
		env[CONFIG.InstanceKey] = nil
	end
end
env[CONFIG.InstanceKey] = destroy

----------------------------------------------------------------------
-- State and persistence
----------------------------------------------------------------------
local player = Players.LocalPlayer
local state = defaultState()

local function loadState()
	if typeof(isfile) ~= "function" or typeof(readfile) ~= "function" then
		return
	end
	local ok, decoded = pcall(function()
		if not isfile(CONFIG.SaveFile) then
			return nil
		end
		return HttpService:JSONDecode(readfile(CONFIG.SaveFile))
	end)
	if ok and decoded ~= nil then
		state = sanitizeState(decoded)
	end
end

local function saveState()
	if typeof(writefile) ~= "function" then
		return
	end
	pcall(function()
		writefile(CONFIG.SaveFile, HttpService:JSONEncode(state))
	end)
end

loadState()

----------------------------------------------------------------------
-- Tools
----------------------------------------------------------------------
local toolNames = {}

local function refreshToolNames()
	local seen, names = {}, {}
	local function scan(container)
		if not container then
			return
		end
		for _, child in ipairs(container:GetChildren()) do
			if child:IsA("Tool") and not seen[child.Name] then
				seen[child.Name] = true
				table.insert(names, child.Name)
			end
		end
	end
	scan(player:FindFirstChildOfClass("Backpack"))
	scan(player.Character)
	table.sort(names)
	toolNames = names
end

local function findTool(name)
	local containers = { player.Character, player:FindFirstChildOfClass("Backpack") }
	for _, container in ipairs(containers) do
		if container then
			for _, child in ipairs(container:GetChildren()) do
				if child:IsA("Tool") and child.Name == name then
					return child
				end
			end
		end
	end
	return nil
end

----------------------------------------------------------------------
-- Timing and synthetic input
----------------------------------------------------------------------
-- Waits at least `ms` milliseconds, measured in whole Heartbeat frames. Because of that,
-- any value below one frame (about 16.7 ms at 60 FPS) behaves as one frame. 0 skips the wait.
local function waitMs(ms)
	if ms <= 0 then
		return
	end
	local start = os.clock()
	repeat
		RunService.Heartbeat:Wait()
	until os.clock() - start >= ms / 1000
end

local function holdFrames()
	for _ = 1, CONFIG.PressHoldHeartbeats do
		RunService.Heartbeat:Wait()
	end
end

local virtualInput = nil
pcall(function()
	virtualInput = game:GetService("VirtualInputManager")
end)

local function pressKey(keyCode)
	if not virtualInput then
		return false
	end
	local down = pcall(function()
		virtualInput:SendKeyEvent(true, keyCode, false, game)
	end)
	if not down then
		return false
	end
	holdFrames()
	pcall(function()
		virtualInput:SendKeyEvent(false, keyCode, false, game)
	end)
	return true
end

local function leftClick(fallbackTool)
	local camera = workspace.CurrentCamera
	if virtualInput and camera then
		local size = camera.ViewportSize
		local x, y = size.X / 2, size.Y / 2
		local down = pcall(function()
			virtualInput:SendMouseButtonEvent(x, y, 0, true, game, 0)
		end)
		if down then
			holdFrames()
			pcall(function()
				virtualInput:SendMouseButtonEvent(x, y, 0, false, game, 0)
			end)
			return true
		end
	end
	if fallbackTool then
		return pcall(function() fallbackTool:Activate() end)
	end
	return false
end

----------------------------------------------------------------------
-- Combo runner
----------------------------------------------------------------------
local running = false
local statusLabel = nil

local function setStatus(text)
	if statusLabel then
		statusLabel.Text = text
	end
end

local function aliveHumanoid(character)
	if not character or player.Character ~= character then
		return nil
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid and humanoid.Health > 0 then
		return humanoid
	end
	return nil
end

local function runCombo(index)
	if running or not alive then
		return
	end
	local combo = state.combos[index]
	if not combo then
		return
	end
	local character = player.Character
	if not aliveHumanoid(character) then
		return
	end

	running = true
	task.spawn(function()
		local ok, err = pcall(function()
			local delayMs = state.delayMs
			for slotIndex, name in ipairs(combo.slots) do
				if not alive then
					return
				end
				if name ~= "" then
					local humanoid = aliveHumanoid(character)
					if not humanoid then
						return
					end
					local tool = findTool(name)
					if tool then
						humanoid:EquipTool(tool)
						waitMs(delayMs)
						if CONFIG.ActivateEachSlot and aliveHumanoid(character) then
							leftClick(tool)
							waitMs(delayMs)
						end
					else
						setStatus(("Combo %d slot %d: tool '%s' not found"):format(index, slotIndex, name))
					end
				end
			end
			if combo.endClick and aliveHumanoid(character) then
				pressKey(NUMBER_KEYCODES[state.hotbarKey])
				waitMs(delayMs)
				leftClick(nil)
			end
		end)
		running = false
		if not ok then
			setStatus("Combo " .. index .. " error: " .. tostring(err))
			warn("[ControllerCombos] combo " .. index .. " failed: " .. tostring(err))
		end
	end)
end

----------------------------------------------------------------------
-- Menu (gamepad navigable: A = next option, X = previous option, B = close)
----------------------------------------------------------------------
local scroll = nil
local cyclers = {}
local menuOpen = false
local rebuild

local function commit()
	saveState()
	rebuild()
end

local function makeGui()
	local screen = Instance.new("ScreenGui")
	screen.Name = "ControllerCombos"
	screen.ResetOnSpawn = false
	screen.DisplayOrder = 1000
	screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screen.Enabled = false

	local parents = { player:WaitForChild("PlayerGui"), CoreGui }
	for _, candidate in ipairs(parents) do
		local ok = pcall(function() screen.Parent = candidate end)
		if ok and screen.Parent == candidate then
			break
		end
	end
	if not screen.Parent then
		screen:Destroy()
		return nil
	end

	local frame = Instance.new("Frame")
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.Position = UDim2.fromScale(0.5, 0.5)
	frame.Size = UDim2.fromScale(0.8, 0.8)
	frame.BackgroundColor3 = Color3.fromRGB(18, 18, 22)
	frame.BorderSizePixel = 0
	frame.Parent = screen

	local constraint = Instance.new("UISizeConstraint")
	constraint.MaxSize = Vector2.new(620, 460)
	constraint.Parent = frame

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = frame

	local title = Instance.new("TextLabel")
	title.Size = UDim2.new(1, -16, 0, 40)
	title.Position = UDim2.fromOffset(8, 4)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.GothamBold
	title.TextSize = 15
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.TextColor3 = Color3.fromRGB(120, 255, 170)
	title.TextWrapped = true
	title.Text = "Combos   |   A: next option   X: previous option   B / "
		.. CONFIG.MenuToggleButton .. ": close"
	title.Parent = frame

	statusLabel = Instance.new("TextLabel")
	statusLabel.AnchorPoint = Vector2.new(0, 1)
	statusLabel.Size = UDim2.new(1, -16, 0, 22)
	statusLabel.Position = UDim2.new(0, 8, 1, -4)
	statusLabel.BackgroundTransparency = 1
	statusLabel.Font = Enum.Font.Gotham
	statusLabel.TextSize = 13
	statusLabel.TextXAlignment = Enum.TextXAlignment.Left
	statusLabel.TextColor3 = Color3.fromRGB(200, 200, 205)
	statusLabel.Text = ""
	statusLabel.Parent = frame

	scroll = Instance.new("ScrollingFrame")
	scroll.Position = UDim2.fromOffset(8, 46)
	scroll.Size = UDim2.new(1, -16, 1, -76)
	scroll.BackgroundTransparency = 1
	scroll.BorderSizePixel = 0
	scroll.ScrollBarThickness = 4
	scroll.CanvasSize = UDim2.new()
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroll.Parent = frame

	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 6)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = scroll

	return screen
end

local orderCounter = 0
local function nextOrder()
	orderCounter += 1
	return orderCounter
end

local function addLabel(text, bold)
	local label = Instance.new("TextLabel")
	label.LayoutOrder = nextOrder()
	label.Size = UDim2.new(1, -8, 0, 0)
	label.AutomaticSize = Enum.AutomaticSize.Y
	label.BackgroundTransparency = 1
	label.Font = bold and Enum.Font.GothamBold or Enum.Font.Gotham
	label.TextSize = bold and 16 or 13
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextWrapped = true
	label.TextColor3 = bold and Color3.fromRGB(235, 235, 240) or Color3.fromRGB(170, 170, 178)
	label.Text = text
	label.Parent = scroll
end

-- onStep(dir) is called with +1 on A / click and -1 on X while the row is selected.
local function addRow(key, text, onStep)
	local button = Instance.new("TextButton")
	button.Name = key
	button.LayoutOrder = nextOrder()
	button.Size = UDim2.new(1, -8, 0, 36)
	button.BackgroundColor3 = Color3.fromRGB(34, 34, 42)
	button.BorderSizePixel = 0
	button.AutoButtonColor = true
	button.Selectable = true
	button.Font = Enum.Font.GothamMedium
	button.TextSize = 14
	button.TextColor3 = Color3.fromRGB(235, 235, 240)
	button.TextXAlignment = Enum.TextXAlignment.Left
	button.Text = "  " .. text
	button.Parent = scroll

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 6)
	corner.Parent = button

	cyclers[key] = onStep
	table.insert(connections, button.Activated:Connect(function()
		onStep(1)
	end))
end

local function slotLabel(name)
	return name == "" and "--" or name
end

rebuild = function()
	if not scroll then
		return
	end
	local selectedKey = GuiService.SelectedObject and GuiService.SelectedObject.Name or nil

	for _, child in ipairs(scroll:GetChildren()) do
		if not child:IsA("UIListLayout") then
			child:Destroy()
		end
	end
	table.clear(cyclers)
	orderCounter = 0

	local buttonSkip = { [CONFIG.MenuToggleButton] = true }

	for i = 1, CONFIG.ComboCount do
		local combo = state.combos[i]
		addLabel("Combo " .. i, true)
		if i == 1 then
			addLabel("Pick tools by name. For brass knuckles use the tool named '1 punches' "
				.. "(your note from the recording). Tools do not need to be on your hotbar.", false)
		end

		addRow(("c%d_button"):format(i), "Controller Button: " .. combo.button, function(dir)
			local nextButton = stepOption(BINDABLE_BUTTONS, combo.button, dir, buttonSkip)
			combo.button = nextButton
			if nextButton ~= "None" then
				for j, other in ipairs(state.combos) do
					if j ~= i and other.button == nextButton then
						other.button = "None"
					end
				end
			end
			commit()
		end)

		addRow(("c%d_end"):format(i), "Hotbar Number + Left Click at End: "
			.. (combo.endClick and "ON" or "OFF"), function()
			combo.endClick = not combo.endClick
			commit()
		end)

		for s, name in ipairs(combo.slots) do
			addRow(("c%d_slot%d"):format(i, s), ("Slot %d: %s"):format(s, slotLabel(name)), function(dir)
				local options = { "" }
				for _, toolName in ipairs(toolNames) do
					table.insert(options, toolName)
				end
				combo.slots[s] = stepOption(options, name, dir, nil)
				commit()
			end)
		end

		addRow(("c%d_add"):format(i), ("+ Add Slot (%d/%d)"):format(#combo.slots, CONFIG.MaxSlotsPerCombo), function()
			if #combo.slots < CONFIG.MaxSlotsPerCombo then
				table.insert(combo.slots, "")
				commit()
			end
		end)

		addRow(("c%d_remove"):format(i), "- Remove Slot", function()
			if #combo.slots > CONFIG.MinSlotsPerCombo then
				table.remove(combo.slots)
				commit()
			end
		end)

		addRow(("c%d_clear"):format(i), "Clear Combo " .. i, function()
			combo.slots = { "" }
			commit()
		end)
	end

	addLabel("Global", true)

	addRow("refresh", "Refresh Tool List (" .. #toolNames .. " tools found)", function()
		refreshToolNames()
		setStatus("Tool list refreshed: " .. #toolNames .. " tools")
		commit()
	end)

	addRow("hotkey", "Combo Hotbar Key: " .. state.hotbarKey, function(dir)
		state.hotbarKey = clampInt(
			((state.hotbarKey - CONFIG.HotbarKeyMin + dir) % (CONFIG.HotbarKeyMax - CONFIG.HotbarKeyMin + 1))
				+ CONFIG.HotbarKeyMin,
			CONFIG.HotbarKeyMin, CONFIG.HotbarKeyMax, CONFIG.DefaultHotbarKey)
		commit()
	end)

	addRow("delay", "Action Delay: " .. state.delayMs .. " ms  (A +1, X -1)", function(dir)
		state.delayMs = clampInt(state.delayMs + dir, CONFIG.DelayMinMs, CONFIG.DelayMaxMs, state.delayMs)
		commit()
	end)
	addRow("delay_up10", "Action Delay +10 ms", function()
		state.delayMs = clampInt(state.delayMs + 10, CONFIG.DelayMinMs, CONFIG.DelayMaxMs, state.delayMs)
		commit()
	end)
	addRow("delay_down10", "Action Delay -10 ms", function()
		state.delayMs = clampInt(state.delayMs - 10, CONFIG.DelayMinMs, CONFIG.DelayMaxMs, state.delayMs)
		commit()
	end)

	addLabel("Defaults are D-pad Left / Up / Right for Combos 1-3. Combo 4 starts unbound. "
		.. "Delays under one frame (about 16.7 ms at 60 FPS) run as one frame.", false)

	if selectedKey then
		local target = scroll:FindFirstChild(selectedKey)
		if target then
			GuiService.SelectedObject = target
		end
	end
end

local function setMenu(open)
	if not gui then
		return
	end
	menuOpen = open
	gui.Enabled = open
	if open then
		refreshToolNames()
		rebuild()
		local first = scroll:FindFirstChild("c1_button")
		if first then
			GuiService.SelectedObject = first
		end
	else
		GuiService.SelectedObject = nil
	end
end

----------------------------------------------------------------------
-- Input
----------------------------------------------------------------------
local function onInputBegan(input)
	if not GAMEPAD_TYPES[input.UserInputType] then
		return
	end
	if UserInputService:GetFocusedTextBox() then
		return
	end
	local buttonName = input.KeyCode.Name

	if buttonName == CONFIG.MenuToggleButton then
		setMenu(not menuOpen)
		return
	end

	if menuOpen then
		if buttonName == "ButtonB" then
			setMenu(false)
		elseif buttonName == "ButtonX" then
			local selected = GuiService.SelectedObject
			local cycler = selected and cyclers[selected.Name]
			if cycler then
				cycler(-1)
			end
		end
		return
	end

	for index, combo in ipairs(state.combos) do
		if combo.button ~= "None" and combo.button == buttonName then
			runCombo(index)
			return
		end
	end
end

----------------------------------------------------------------------
-- Startup
----------------------------------------------------------------------
gui = makeGui()
if not gui then
	warn("[ControllerCombos] could not parent the menu to PlayerGui or CoreGui")
	destroy()
	return
end

table.insert(connections, UserInputService.InputBegan:Connect(onInputBegan))
-- Releases nothing held by us: synthetic key/click releases are sent inside pressKey/leftClick.

setStatus("Ready. Open the menu with " .. CONFIG.MenuToggleButton .. ".")
print("[ControllerCombos] loaded. Menu toggle: " .. CONFIG.MenuToggleButton)
