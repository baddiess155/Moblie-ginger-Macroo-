-- BaddiesToolkit.lua  (v2: adds auto aim)
-- Luau, Roblox client. Not run or tested by the author.
-- Standard Roblox APIs only. The only executor-specific call is the optional gethui(), guarded by pcall.
-- Coordinate system: Roblox world is Y-up, right-handed, units are studs. Angles in config are degrees.

if _G.BaddiesToolkit_Unload then
	pcall(_G.BaddiesToolkit_Unload)
end

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local LocalPlayer = Players.LocalPlayer
assert(LocalPlayer, "BaddiesToolkit: no LocalPlayer (run this on the client)")

---------------------------------------------------------------------------
-- CONFIG: every build-dependent or untuned value lives here.
-- nil = UNSET. 0 is a real value. Nothing below came from the game's files.
---------------------------------------------------------------------------
local CONFIG = {
	-- Source: display label "Space Rocket Launcher" seen in the video (hotbar slot 5 / pickup text).
	-- UNVERIFIED as the Tool instance's Name. Lowercase substring match.
	ToolNamePattern = "space rocket launcher",

	-- UNSET: names of the cooldown/delay attribute(s) or NumberValue(s) on the tool.
	-- Fill from the "Inspect RPG tool" output, e.g. CooldownKeys = { "<name you confirmed>" }.
	CooldownKeys = nil,

	-- The value written while Zero delay is on. A deliberate 0, not a default.
	CooldownTargetValue = 0,

	-- Search terms for the inspector only. These are heuristics, not game data.
	CandidatePatterns = { "cool", "delay", "rate", "reload", "debounce", "interval" },

	AutoAim = {
		-- Standard Roblox rig part names, tried in order. UNVERIFIED for Baddies characters.
		AimPartNames = { "Head", "HumanoidRootPart" },

		-- UNCALIBRATED values: starting points only, tune them on your device.
		FovDegrees = 30, -- half-angle of the cone around the camera's look direction
		MaxDistanceStuds = 500,
		SmoothingRate = 12, -- per second; higher = snappier camera
		StickinessFov = 1.25, -- keep the current target until it leaves FovDegrees * this

		RequireLineOfSight = true, -- raycast from camera to aim part; invisible barriers may block it
		IgnoreSameTeam = true, -- applied only when you and the other player both have a Team

		-- UNSET: projectile speed of the launcher in studs/second. Needed to lead moving targets.
		-- While nil, the camera aims straight at the target with no lead.
		ProjectileSpeedStudsPerSec = nil,
	},
}

local AIM = CONFIG.AutoAim

---------------------------------------------------------------------------
-- Pure math (no game access, checkable on their own)
---------------------------------------------------------------------------
local function isFiniteVector(v)
	local limit = 1e6
	return v.X == v.X and v.Y == v.Y and v.Z == v.Z
		and math.abs(v.X) < limit and math.abs(v.Y) < limit and math.abs(v.Z) < limit
end

local function angleBetweenDegrees(a, b)
	local ma, mb = a.Magnitude, b.Magnitude
	if ma < 1e-6 or mb < 1e-6 then
		return math.huge
	end
	local c = math.clamp(a:Dot(b) / (ma * mb), -1, 1)
	return math.deg(math.acos(c))
end

local function smoothAlpha(rate, dt)
	return 1 - math.exp(-rate * dt)
end

-- First-order lead: where the target will be when a projectile of constant speed arrives.
local function leadPoint(targetPos, targetVel, originPos, speed)
	if not speed or speed <= 0 then
		return targetPos
	end
	local travelTime = (targetPos - originPos).Magnitude / speed
	return targetPos + targetVel * travelTime
end

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------
local AIM_STEP_NAME = "BaddiesToolkitAutoAim"
local alive = true
local zeroDelayOn = false
local aimOn = false
local currentTarget = nil -- Player
local lastLoggedTarget = nil
local connections = {}
local attrOriginals = setmetatable({}, { __mode = "k" }) -- [instance][key] = original number
local valueOriginals = setmetatable({}, { __mode = "k" }) -- [NumberValue/IntValue] = original number
local logLines = {}
local logLabel = nil

local function log(line)
	logLines[#logLines + 1] = line
	if #logLines > 200 then
		table.remove(logLines, 1)
	end
	print("[BaddiesToolkit] " .. line)
	if logLabel then
		logLabel.Text = table.concat(logLines, "\n")
	end
end

---------------------------------------------------------------------------
-- Tool lookup and inspection
---------------------------------------------------------------------------
local function findRocketTool()
	local containers = {}
	if LocalPlayer.Character then
		containers[#containers + 1] = LocalPlayer.Character
	end
	local backpack = LocalPlayer:FindFirstChildOfClass("Backpack")
	if backpack then
		containers[#containers + 1] = backpack
	end
	for _, container in ipairs(containers) do
		for _, child in ipairs(container:GetChildren()) do
			if child:IsA("Tool") and string.find(string.lower(child.Name), CONFIG.ToolNamePattern, 1, true) then
				return child
			end
		end
	end
	return nil
end

local function isCandidateName(name)
	local lower = string.lower(name)
	for _, pattern in ipairs(CONFIG.CandidatePatterns) do
		if string.find(lower, pattern, 1, true) then
			return true
		end
	end
	return false
end

local function inspectTool()
	local tool = findRocketTool()
	if not tool then
		log("No Tool matching '" .. CONFIG.ToolNamePattern .. "' in Character or Backpack. Pick it up or fix ToolNamePattern.")
		return
	end
	local prefix = tool:GetFullName()
	log("Tool: " .. prefix .. " [" .. tool.ClassName .. "]")
	local function dumpAttributes(inst, label)
		for name, value in pairs(inst:GetAttributes()) do
			log(string.format("  attr %s.%s = %s (%s)%s", label, name, tostring(value), typeof(value),
				isCandidateName(name) and "  <candidate>" or ""))
		end
	end
	dumpAttributes(tool, "(tool)")
	for _, d in ipairs(tool:GetDescendants()) do
		local rel = string.sub(d:GetFullName(), #prefix + 2)
		local valueText = ""
		if d:IsA("ValueBase") then
			valueText = " = " .. tostring(d.Value)
		end
		log(string.format("  %s [%s]%s%s", rel, d.ClassName, valueText,
			isCandidateName(d.Name) and "  <candidate>" or ""))
		dumpAttributes(d, rel)
	end
	log("Inspect done. Script source is not readable here; RemoteEvent/RemoteFunction entries above are fire paths.")
end

---------------------------------------------------------------------------
-- Zero delay (gated on CONFIG.CooldownKeys)
---------------------------------------------------------------------------
local function applyPass()
	local tool = findRocketTool()
	if not tool then
		return
	end
	local keys = CONFIG.CooldownKeys
	local target = CONFIG.CooldownTargetValue
	local function visit(inst)
		for _, key in ipairs(keys) do
			local current = inst:GetAttribute(key)
			if type(current) == "number" then
				attrOriginals[inst] = attrOriginals[inst] or {}
				if attrOriginals[inst][key] == nil then
					attrOriginals[inst][key] = current
				end
				if current ~= target then
					inst:SetAttribute(key, target)
				end
			end
		end
		if (inst:IsA("NumberValue") or inst:IsA("IntValue")) and table.find(keys, inst.Name) then
			if valueOriginals[inst] == nil then
				valueOriginals[inst] = inst.Value
			end
			if inst.Value ~= target then
				inst.Value = target
			end
		end
	end
	visit(tool)
	for _, d in ipairs(tool:GetDescendants()) do
		visit(d)
	end
end

local function restoreOriginals()
	for inst, keys in pairs(attrOriginals) do
		for key, original in pairs(keys) do
			pcall(inst.SetAttribute, inst, key, original)
		end
	end
	for obj, original in pairs(valueOriginals) do
		pcall(function()
			obj.Value = original
		end)
	end
	table.clear(attrOriginals)
	table.clear(valueOriginals)
end

---------------------------------------------------------------------------
-- Auto aim: rotates the camera toward the best valid target each frame.
-- It emits no input, so there is nothing held to release on stop.
---------------------------------------------------------------------------
local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude

local function localCharacterAlive()
	local character = LocalPlayer.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	return humanoid ~= nil and humanoid.Health > 0
end

local function isTeammate(player)
	return AIM.IgnoreSameTeam and LocalPlayer.Team ~= nil and player.Team == LocalPlayer.Team
end

-- Returns character, aimPart or nil when the player is not a valid target.
local function getTargetParts(player)
	if player == LocalPlayer or isTeammate(player) then
		return nil
	end
	local character = player.Character
	if not character then
		return nil
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return nil
	end
	for _, partName in ipairs(AIM.AimPartNames) do
		local part = character:FindFirstChild(partName)
		if part and part:IsA("BasePart") and isFiniteVector(part.Position) then
			return character, part
		end
	end
	return nil
end

local function hasLineOfSight(origin, aimPart, targetCharacter)
	local ignore = { targetCharacter }
	if LocalPlayer.Character then
		ignore[#ignore + 1] = LocalPlayer.Character
	end
	rayParams.FilterDescendantsInstances = ignore
	return Workspace:Raycast(origin, aimPart.Position - origin, rayParams) == nil
end

-- Returns angle in degrees, or nil if the player fails range, FOV or line-of-sight checks.
local function scoreTarget(player, camCF, fovLimit)
	local character, part = getTargetParts(player)
	if not character then
		return nil
	end
	local offset = part.Position - camCF.Position
	if offset.Magnitude > AIM.MaxDistanceStuds then
		return nil
	end
	local angle = angleBetweenDegrees(camCF.LookVector, offset)
	if angle > fovLimit then
		return nil
	end
	if AIM.RequireLineOfSight and not hasLineOfSight(camCF.Position, part, character) then
		return nil
	end
	return angle, part
end

local function pickTarget(camCF)
	local bestPlayer, bestAngle = nil, nil
	for _, player in ipairs(Players:GetPlayers()) do
		local angle = scoreTarget(player, camCF, AIM.FovDegrees)
		if angle and (bestAngle == nil or angle < bestAngle) then
			bestPlayer, bestAngle = player, angle
		end
	end
	return bestPlayer
end

local function aimStep(dt)
	local camera = Workspace.CurrentCamera
	if not camera or not localCharacterAlive() then
		currentTarget = nil
		return
	end
	local camCF = camera.CFrame

	-- Recheck the current target every frame; keep it while it stays inside the sticky cone.
	if currentTarget then
		local angle = scoreTarget(currentTarget, camCF, AIM.FovDegrees * AIM.StickinessFov)
		if not angle then
			currentTarget = nil
		end
	end
	if not currentTarget then
		currentTarget = pickTarget(camCF)
	end
	if currentTarget ~= lastLoggedTarget then
		lastLoggedTarget = currentTarget
		log("Aim target: " .. (currentTarget and currentTarget.Name or "none"))
	end
	if not currentTarget then
		return
	end

	local _, part = getTargetParts(currentTarget)
	if not part then
		currentTarget = nil
		return
	end
	local aimPos = leadPoint(part.Position, part.AssemblyLinearVelocity, camCF.Position,
		AIM.ProjectileSpeedStudsPerSec)
	if not isFiniteVector(aimPos) or (aimPos - camCF.Position).Magnitude < 1e-3 then
		return
	end
	local desired = CFrame.lookAt(camCF.Position, aimPos)
	camera.CFrame = camCF:Lerp(desired, smoothAlpha(AIM.SmoothingRate, dt))
end

local function stopAim()
	pcall(function()
		RunService:UnbindFromRenderStep(AIM_STEP_NAME)
	end)
	aimOn = false
	currentTarget = nil
	lastLoggedTarget = nil
end

local function startAim()
	aimOn = true
	-- Runs just after the default camera script so our rotation is the last write each frame.
	RunService:BindToRenderStep(AIM_STEP_NAME, Enum.RenderPriority.Camera.Value + 1, function(dt)
		local ok, err = pcall(aimStep, dt)
		if not ok then
			log("aimStep failed, auto aim stopped: " .. tostring(err))
			stopAim()
		end
	end)
end

---------------------------------------------------------------------------
-- UI (touch-first: 48px buttons, Activated works for touch and mouse)
---------------------------------------------------------------------------
local function pickGuiParent()
	local ok, hui = pcall(function()
		return gethui and gethui() or nil
	end)
	if ok and hui then
		return hui
	end
	return LocalPlayer:WaitForChild("PlayerGui")
end

local gui = Instance.new("ScreenGui")
gui.Name = "BaddiesToolkit"
gui.ResetOnSpawn = false
gui.DisplayOrder = 100
gui.Parent = pickGuiParent()

local panel = Instance.new("Frame")
panel.Size = UDim2.fromOffset(250, 40)
panel.Position = UDim2.fromOffset(12, 60)
panel.BackgroundColor3 = Color3.fromRGB(24, 24, 28)
panel.BorderSizePixel = 0
panel.AutomaticSize = Enum.AutomaticSize.Y
panel.Parent = gui
Instance.new("UICorner", panel).CornerRadius = UDim.new(0, 8)

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, -48, 0, 40)
title.BackgroundTransparency = 1
title.Text = "  Baddies Toolkit (drag)"
title.TextXAlignment = Enum.TextXAlignment.Left
title.TextColor3 = Color3.new(1, 1, 1)
title.Font = Enum.Font.GothamBold
title.TextSize = 14
title.Parent = panel

local body = Instance.new("Frame")
body.Position = UDim2.fromOffset(0, 40)
body.Size = UDim2.new(1, 0, 0, 0)
body.AutomaticSize = Enum.AutomaticSize.Y
body.BackgroundTransparency = 1
body.Parent = panel
local layout = Instance.new("UIListLayout")
layout.Padding = UDim.new(0, 6)
layout.SortOrder = Enum.SortOrder.LayoutOrder
layout.Parent = body
local pad = Instance.new("UIPadding")
pad.PaddingLeft, pad.PaddingRight, pad.PaddingBottom = UDim.new(0, 8), UDim.new(0, 8), UDim.new(0, 8)
pad.Parent = body

local function makeButton(text, parent, order)
	local b = Instance.new("TextButton")
	b.Size = UDim2.new(1, 0, 0, 48)
	b.LayoutOrder = order or 0
	b.BackgroundColor3 = Color3.fromRGB(50, 50, 60)
	b.TextColor3 = Color3.new(1, 1, 1)
	b.Font = Enum.Font.Gotham
	b.TextSize = 14
	b.Text = text
	b.AutoButtonColor = true
	b.Parent = parent
	Instance.new("UICorner", b).CornerRadius = UDim.new(0, 6)
	return b
end

local collapseBtn = makeButton("-", panel)
collapseBtn.Size = UDim2.fromOffset(40, 40)
collapseBtn.Position = UDim2.new(1, -44, 0, 0)

local inspectBtn = makeButton("Inspect RPG tool", body, 1)
local zeroBtn = makeButton("RPG zero delay: OFF", body, 2)
local aimBtn = makeButton("Auto aim: OFF", body, 3)
local unloadBtn = makeButton("Unload", body, 4)

local logBox = Instance.new("ScrollingFrame")
logBox.Size = UDim2.new(1, 0, 0, 170)
logBox.LayoutOrder = 5
logBox.BackgroundColor3 = Color3.fromRGB(14, 14, 18)
logBox.BorderSizePixel = 0
logBox.CanvasSize = UDim2.new()
logBox.AutomaticCanvasSize = Enum.AutomaticSize.Y
logBox.ScrollBarThickness = 6
logBox.Parent = body

logLabel = Instance.new("TextLabel")
logLabel.Size = UDim2.new(1, -8, 0, 0)
logLabel.AutomaticSize = Enum.AutomaticSize.Y
logLabel.BackgroundTransparency = 1
logLabel.TextWrapped = true
logLabel.TextXAlignment = Enum.TextXAlignment.Left
logLabel.TextYAlignment = Enum.TextYAlignment.Top
logLabel.TextColor3 = Color3.fromRGB(210, 210, 220)
logLabel.Font = Enum.Font.Code
logLabel.TextSize = 11
logLabel.Text = ""
logLabel.Parent = logBox

local function setZeroText()
	zeroBtn.Text = "RPG zero delay: " .. (zeroDelayOn and "ON" or "OFF")
end

local function setAimText()
	aimBtn.Text = "Auto aim: " .. (aimOn and "ON" or "OFF")
end

-- Dragging by the title bar (mouse or touch)
do
	local dragging, dragStart, startPos = false, nil, nil
	connections[#connections + 1] = title.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging, dragStart, startPos = true, input.Position, panel.Position
			local c
			c = input.Changed:Connect(function()
				if input.UserInputState == Enum.UserInputState.End then
					dragging = false
					c:Disconnect()
				end
			end)
		end
	end)
	connections[#connections + 1] = UserInputService.InputChanged:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			local delta = input.Position - dragStart
			panel.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
		end
	end)
end

---------------------------------------------------------------------------
-- Wiring and shared cleanup (failed init and normal shutdown share unload)
---------------------------------------------------------------------------
local function unload()
	if not alive then
		return
	end
	alive = false
	zeroDelayOn = false
	stopAim()
	restoreOriginals()
	for _, c in ipairs(connections) do
		c:Disconnect()
	end
	table.clear(connections)
	if gui then
		gui:Destroy()
	end
	_G.BaddiesToolkit_Unload = nil
end
_G.BaddiesToolkit_Unload = unload

local function startLoop()
	task.spawn(function()
		while alive and zeroDelayOn do
			local ok, err = pcall(applyPass)
			if not ok then
				log("applyPass failed, zero delay stopped: " .. tostring(err))
				zeroDelayOn = false
				restoreOriginals()
				setZeroText()
				break
			end
			task.wait(0.1) -- re-asserts the value in case the game rewrites it after each shot
		end
	end)
end

connections[#connections + 1] = collapseBtn.Activated:Connect(function()
	body.Visible = not body.Visible
	collapseBtn.Text = body.Visible and "-" or "+"
end)

connections[#connections + 1] = inspectBtn.Activated:Connect(function()
	local ok, err = pcall(inspectTool)
	if not ok then
		log("inspect failed: " .. tostring(err))
	end
end)

connections[#connections + 1] = zeroBtn.Activated:Connect(function()
	if CONFIG.CooldownKeys == nil then
		log("GATED: CONFIG.CooldownKeys is unset. Run 'Inspect RPG tool', confirm the real cooldown name(s), put them in CONFIG.CooldownKeys.")
		return
	end
	zeroDelayOn = not zeroDelayOn
	setZeroText()
	if zeroDelayOn then
		log("Zero delay ON for keys: " .. table.concat(CONFIG.CooldownKeys, ", "))
		startLoop()
	else
		restoreOriginals()
		log("Zero delay OFF, original values restored.")
	end
end)

connections[#connections + 1] = aimBtn.Activated:Connect(function()
	if aimOn then
		stopAim()
		log("Auto aim OFF.")
	else
		startAim()
		if AIM.ProjectileSpeedStudsPerSec == nil then
			log("Auto aim ON (no lead: ProjectileSpeedStudsPerSec is unset, so moving targets will be missed by slow projectiles).")
		else
			log("Auto aim ON with lead at " .. tostring(AIM.ProjectileSpeedStudsPerSec) .. " studs/s.")
		end
	end
	setAimText()
end)

-- Stop aiming when the app loses focus.
connections[#connections + 1] = UserInputService.WindowFocusReleased:Connect(function()
	if aimOn then
		stopAim()
		setAimText()
		log("Auto aim stopped: window lost focus.")
	end
end)

connections[#connections + 1] = unloadBtn.Activated:Connect(unload)

log("Loaded. Hold the rocket launcher, tap 'Inspect RPG tool' for cooldown names, tap 'Auto aim' to toggle aiming.")
setZeroText()
setAimText()
