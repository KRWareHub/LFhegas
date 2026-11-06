--// Plasma Hub Lite -------------------------------------------------------
-- Hitbox expander + Infinite Stamina only.
--
-- Safety rules carried over from the full hub (placeVersion 358):
--   * Hit.overlapCheck is NEVER written or hooked. The ExternalProbe shim
--     compares it with == (isOverlapProbeIntact) and feeds it a fake
--     newproxy(true); leaving it alone keeps that check true by
--     construction. The expander rides the real module-local queryOverlap,
--     which the kick loop and the shim share.
--   * No security evidence predicates are detoured (EvidencePredicateTamper).
--   * No fingerprinted toggle texts: "Hitbox Expander" / "Infinite Stamina".
--     The window is named Plasma Hub; the game's plasmaHub fingerprint needs
--     all THREE exact strings ("plasma hub" + "enable hitbox expander" +
--     "enable infinite stamina"), so the name alone does not match it.
--   * Runtime objects use generic names (ReachArea), never LFH_*.
--   * Limb/ball sizes are restored inside the same resumption, so the
--     deferred LimbSizeMonitor handler reads the vanilla size.
--   * Hooks are installed only while their feature is enabled. With both
--     features off, queryOverlap and staminaFill.advance are restored to
--     vanilla, leaving only the public ForceSprintStop handler slot.
--   * Before arming and periodically while armed, the lite re-checks that
--     Hit.overlapCheck is still untouched and that a synthetic newproxy
--     fake remains opaque to the wrapper. A failure disables features and
--     removes hooks instead of continuing into a flagged state.
--   * Load-time sweep removes orphaned legacy LFH_* artifacts from older
--     sessions, including the detector's holder/ball ESP names.

local genv = getgenv()
local S = genv.__LFH_LEAGUE
if type(S) ~= "table" then
	S = {
		cfg = {},
		hooks = {},
		fnHooks = {},
		abHooks = {},
		conns = {},
		drawings = {},
		visParts = {},
		runId = 0,
		win = nil,
	}
	genv.__LFH_LEAGUE = S
end

-- The state table survives reloads and may have been created by the full
-- hub, so backfill every field teardown touches.
S.cfg = S.cfg or {}
S.hooks = S.hooks or {}
S.fnHooks = S.fnHooks or {}
S.abHooks = S.abHooks or {}
S.conns = S.conns or {}
S.drawings = S.drawings or {}
S.visParts = S.visParts or {}

local cfg = S.cfg
cfg.hitboxEnabled = false
cfg.hitboxMult = type(cfg.hitboxMult) == "number" and cfg.hitboxMult or 1.5
cfg.hitboxMethod = cfg.hitboxMethod == "ball" and "ball" or "humanoid"
cfg.hitboxVis = false
cfg.hitboxVisAlpha = type(cfg.hitboxVisAlpha) == "number" and cfg.hitboxVisAlpha or 0.5
cfg.hitboxVisColor = typeof(cfg.hitboxVisColor) == "Color3" and cfg.hitboxVisColor or Color3.fromRGB(255, 60, 60)
cfg.infStamina = false

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local window
local runId
local visByLimb = {}
local hitboxArmed = false
local staminaArmed = false
local safetyLocked = false
local hitboxToggle = nil
local staminaToggle = nil

--// ---------------------------------------------------------------- teardown
local function teardown()
	S.runId += 1

	for _, c in ipairs(S.conns) do
		pcall(function()
			c:Disconnect()
		end)
	end
	S.conns = {}

	for _, d in ipairs(S.drawings) do
		pcall(function()
			d:Remove()
		end)
	end
	S.drawings = {}

	for _, p in ipairs(S.visParts) do
		pcall(function()
			p:Destroy()
		end)
	end
	S.visParts = {}

	for _, h in ipairs(S.hooks) do
		pcall(function()
			h.tbl[h.key] = h.orig
		end)
	end
	S.hooks = {}

	for _, h in ipairs(S.fnHooks) do
		pcall(function()
			hookfunction(h.fn, h.orig)
		end)
	end
	S.fnHooks = {}

	-- Legacy evidence-gate detours from older sessions only.
	for _, h in ipairs(S.abHooks) do
		pcall(function()
			hookfunction(h.fn, h.orig)
		end)
	end
	S.abHooks = {}

	if S.holder then
		pcall(function()
			S.holder:Destroy()
		end)
		S.holder = nil
	end

	if S.win then
		pcall(function()
			S.win:Unload()
		end)
		S.win = nil
	end
end
teardown()
runId = S.runId

--// ---------------------------------------------------------------- module access
local function descend(root, names)
	local node = root
	for _, n in ipairs(names) do
		if typeof(node) ~= "Instance" then
			return nil
		end
		node = node:FindFirstChild(n)
	end
	return node
end

local function resolveModules()
	local lp = Players.LocalPlayer
	if typeof(lp) ~= "Instance" then
		return nil, "LocalPlayer"
	end
	local client = descend(lp, { "PlayerScripts", "Client" })
	if not client then
		return nil, "PlayerScripts.Client"
	end
	local hit = descend(client, { "systems", "tools", "internal", "Hit" })
	if not hit then
		return nil, "Client.systems.tools.internal.Hit"
	end
	local stamina = descend(client, { "systems", "stamina" })
	if not stamina then
		return nil, "Client.systems.stamina"
	end
	local netStamina = descend(client, { "network", "stamina" })
	if not netStamina then
		return nil, "Client.network.stamina"
	end
	local fill = descend(ReplicatedStorage, { "Shared", "movement", "staminaFill" })
	if not fill then
		return nil, "Shared.movement.staminaFill"
	end
	return { Hit = hit, Stamina = stamina, NetStamina = netStamina, Fill = fill }
end

local mods, missing
local deadline = os.clock() + 120
repeat
	mods, missing = resolveModules()
	if mods then
		break
	end
	task.wait(0.5)
until os.clock() >= deadline
if not mods then
	warn("[Match] Game modules not found (last missing: " .. tostring(missing) .. ")")
	return
end

local okHit, Hit = pcall(require, mods.Hit)
local okStam, Stamina = pcall(require, mods.Stamina)
local okNet, NetStamina = pcall(require, mods.NetStamina)
local okFill, staminaFill = pcall(require, mods.Fill)
if not (okHit and okStam and okNet and okFill) then
	warn("[Match] Module load failed")
	return
end

--// ---------------------------------------------------------------- ball helper
-- Same filter as the full hub: the CollectionService "Ball" tag also lands on
-- anchored template parts inside ReplicatedStorage, so the fallback only
-- accepts unanchored, in-world assembly roots.
local function getBallPart()
	local wrapper = workspace:FindFirstChild("CurrentMatchBall")
	if wrapper then
		if wrapper:IsA("ObjectValue") then
			local v = wrapper.Value
			if v and v:IsA("BasePart") and v.Parent then
				return v
			end
		elseif wrapper:IsA("BasePart") and wrapper.Parent then
			return wrapper
		end
	end
	for _, p in ipairs(CollectionService:GetTagged("Ball")) do
		if p:IsA("BasePart") and p.Parent and not p.Anchored and p:IsDescendantOf(workspace) and p.AssemblyRootPart == p then
			return p
		end
	end
	return nil
end

-- Older full-hub builds created LFH_*-named artifacts that the security
-- module matches by exact name. The lite never creates them, but a crashed
-- or aborted session can leave orphans behind, so remove any stragglers
-- once at load. Current runtime object names (ReachArea, MatchSessionSync)
-- are intentionally not targeted here except for stale camera parts.
local LEGACY_NAMES = {
	LFH_HitboxOverlay = true,
	LFH_PredDot = true,
	LFH_PredLanding = true,
	LFH_LeagueFootballLiveHolder = true,
	LFH_BallHighlight = true,
	LFH_BallTag = true,
}

local function isLegacyName(name)
	if LEGACY_NAMES[name] then
		return true
	end
	return typeof(name) == "string" and string.sub(name, 1, 4) == "LFH_"
end

local function sweepLegacy()
	pcall(function()
		for _, d in ipairs(workspace:GetDescendants()) do
			if isLegacyName(d.Name) then
				pcall(function()
					d:Destroy()
				end)
			end
		end
	end)
	local cam = workspace.CurrentCamera
	if cam then
		for _, d in ipairs(cam:GetChildren()) do
			if isLegacyName(d.Name) or d.Name == "ReachArea" then
				pcall(function()
					d:Destroy()
				end)
			end
		end
	end
	local ball = getBallPart()
	if ball then
		for _, d in ipairs(ball:GetChildren()) do
			if isLegacyName(d.Name) then
				pcall(function()
					d:Destroy()
				end)
			end
		end
	end
end

sweepLegacy()

--// ---------------------------------------------------------------- hitbox overlay
local function refreshVisPart(limb, size)
	local entry = visByLimb[limb]
	local vp = entry and entry.part

	if not vp or not vp.Parent then
		vp = Instance.new("Part")
		vp.Name = "ReachArea"
		vp.Anchored = true
		vp.CanCollide = false
		vp.CanTouch = false
		vp.CanQuery = false
		vp.CastShadow = false
		vp.Material = Enum.Material.Neon
		vp.Color = cfg.hitboxVisColor
		vp.Transparency = cfg.hitboxVisAlpha
		vp.Parent = workspace.CurrentCamera
		table.insert(S.visParts, vp)
		entry = { part = vp }
		visByLimb[limb] = entry
	end

	vp.Size = size
	vp.CFrame = limb.CFrame
	vp.Transparency = cfg.hitboxVisAlpha
	vp.Color = cfg.hitboxVisColor
	if limb:IsA("Part") and limb.Shape == Enum.PartType.Ball then
		vp.Shape = Enum.PartType.Ball
	end
	entry.size = size
	entry.seen = os.clock()
end

local function sweepOverlays()
	local now = os.clock()
	for limb, entry in pairs(visByLimb) do
		if not cfg.hitboxVis or not entry.part.Parent or now - (entry.seen or 0) > 0.15 then
			pcall(function()
				entry.part:Destroy()
			end)
			visByLimb[limb] = nil
		end
	end
end

local function syncOverlays()
	for limb, entry in pairs(visByLimb) do
		local ok, live = pcall(function()
			return limb ~= nil and limb.Parent ~= nil and entry.part ~= nil and entry.part.Parent ~= nil
		end)
		if not ok or not live then
			pcall(function()
				entry.part:Destroy()
			end)
			visByLimb[limb] = nil
		else
			pcall(function()
				entry.part.CFrame = limb.CFrame
				entry.part.Transparency = cfg.hitboxVisAlpha
				entry.part.Color = cfg.hitboxVisColor
			end)
		end
	end
end

local function clearOverlays()
	for _, p in ipairs(S.visParts) do
		pcall(function()
			p:Destroy()
		end)
	end
	S.visParts = {}
	for limb in pairs(visByLimb) do
		visByLimb[limb] = nil
	end
end

--// ---------------------------------------------------------------- hitbox hook
-- Place version 358: the per-frame kick loop calls the module-local
-- queryOverlap directly; Hit.overlapCheck is only the ExternalProbe shim.
-- overlapProbe has exactly one function upvalue, queryOverlap, so resolve it
-- from there and hook that object. Every closure that captured it, including
-- the live kick loop, then runs the wrapper.
local queryOverlap = nil
do
	local okUps, ups = false, nil
	if typeof(debug) == "table" and typeof(debug.getupvalues) == "function" then
		okUps, ups = pcall(function()
			return debug.getupvalues(Hit.overlapCheck)
		end)
	end
	if okUps and typeof(ups) == "table" then
		for _, v in ipairs(ups) do
			if typeof(v) == "function" then
				queryOverlap = v
				break
			end
		end
	end
	if not queryOverlap and typeof(debug) == "table" and typeof(debug.getupvalue) == "function" then
		-- Standard Lua returns (name, value); this executor returns the value
		-- alone. Accept whichever slot holds the function.
		local okU, a, b = pcall(function()
			return debug.getupvalue(Hit.overlapCheck, 1)
		end)
		if okU then
			if typeof(a) == "function" then
				queryOverlap = a
			elseif typeof(b) == "function" then
				queryOverlap = b
			end
		end
	end
end

local origOverlap = queryOverlap

local function overlapCheckBallExpanded(part)
	local okBall, ball = pcall(getBallPart)
	if not okBall or typeof(ball) ~= "Instance" or ball == part then
		return origOverlap(part)
	end

	local okSize, saved = pcall(function()
		return ball.Size
	end)
	if not okSize then
		return origOverlap(part)
	end

	local expanded = false
	local ok, res = pcall(function()
		local grown = saved * cfg.hitboxMult
		ball.Size = grown
		expanded = true
		local found = origOverlap(part)
		if cfg.hitboxVis then
			pcall(refreshVisPart, ball, grown)
		end
		ball.Size = saved
		expanded = false
		return found
	end)

	if expanded then
		pcall(function()
			ball.Size = saved
		end)
	end

	if ok and typeof(res) == "table" then
		return res
	end
	return {}
end

local function overlapCheckLimbExpanded(part)
	local okSize, saved = pcall(function()
		return part.Size
	end)
	if not okSize then
		return origOverlap(part)
	end

	local expanded = false
	local ok, res = pcall(function()
		local grown = saved * cfg.hitboxMult
		part.Size = grown
		expanded = true
		local found = origOverlap(part)
		if cfg.hitboxVis then
			pcall(refreshVisPart, part, grown)
		end
		part.Size = saved
		expanded = false
		return found
	end)

	if expanded then
		pcall(function()
			part.Size = saved
		end)
	end

	if ok and typeof(res) == "table" then
		return res
	end
	return {}
end

local function overlapDispatch(part)
	-- type() never consults metamethods; typeof() only reads __type. The probe
	-- fake has no __type, so this check never triggers its handlers.
	if type(part) ~= "userdata" or typeof(part) ~= "Instance" then
		error("attempt to index a userdata value", 2)
	end

	if not cfg.hitboxEnabled or cfg.hitboxMult <= 1.001 then
		return origOverlap(part)
	end

	if cfg.hitboxMethod == "ball" then
		return overlapCheckBallExpanded(part)
	end
	return overlapCheckLimbExpanded(part)
end

local function removeHitboxHookEntry()
	for i = #S.fnHooks, 1, -1 do
		if S.fnHooks[i].fn == queryOverlap then
			table.remove(S.fnHooks, i)
		end
	end
end

local function armHitbox()
	if hitboxArmed then
		return true
	end
	if safetyLocked or not queryOverlap or typeof(hookfunction) ~= "function" then
		return false
	end
	local okHook, hookedOrig = pcall(hookfunction, queryOverlap, overlapDispatch)
	if not okHook or typeof(hookedOrig) ~= "function" then
		return false
	end
	origOverlap = hookedOrig
	hitboxArmed = true
	table.insert(S.fnHooks, { fn = queryOverlap, orig = hookedOrig })
	return true
end

local function disarmHitbox()
	if not hitboxArmed then
		return
	end
	local okRestore = pcall(function()
		return hookfunction(queryOverlap, origOverlap)
	end)
	if not okRestore then
		return
	end
	hitboxArmed = false
	removeHitboxHookEntry()
	clearOverlays()
end

--// ---------------------------------------------------------------- infinite stamina
-- All client-side drain goes through the pure helper
-- ReplicatedStorage.Shared.movement.staminaFill.advance (the sprint heartbeat
-- and the HUD bar both call it). While draining, re-run it with
-- draining=false: the bar refills and the heartbeat's <= 0.001 stop test
-- never fires. No game script outside the stamina module reads this helper.
local origAdvance = nil

local function staminaDispatch(fill, dt, maxFill, draining)
	if cfg.infStamina and draining then
		return origAdvance(fill, dt, maxFill, false)
	end
	return origAdvance(fill, dt, maxFill, draining)
end

local function removeStaminaHookEntry()
	for i = #S.fnHooks, 1, -1 do
		if S.fnHooks[i].fn == staminaFill.advance then
			table.remove(S.fnHooks, i)
		end
	end
end

local function armStamina()
	if staminaArmed then
		return true
	end
	if safetyLocked or typeof(staminaFill.advance) ~= "function" or typeof(hookfunction) ~= "function" then
		return false
	end
	local okHook, hookedOrig = pcall(hookfunction, staminaFill.advance, staminaDispatch)
	if not okHook or typeof(hookedOrig) ~= "function" then
		return false
	end
	origAdvance = hookedOrig
	staminaArmed = true
	table.insert(S.fnHooks, { fn = staminaFill.advance, orig = hookedOrig })
	return true
end

local function disarmStamina()
	if not staminaArmed then
		return
	end
	local okRestore = pcall(function()
		return hookfunction(staminaFill.advance, origAdvance)
	end)
	if not okRestore then
		return
	end
	staminaArmed = false
	removeStaminaHookEntry()
end

--// ---------------------------------------------------------------- probe self-check / fail-closed watchdog
-- This mirrors the game's own trap probe with our own fake: Hit.overlapCheck
-- must still be the vanilla function, and our wrapper must reject the fake
-- without firing any metamethods. When armed, it runs every 3 seconds; a
-- failed check removes hooks, clears overlays and turns both features off.
local function probeSelfTest()
	local okIntact, intact = pcall(function()
		return Hit.isOverlapProbeIntact()
	end)
	if not okIntact or intact ~= true then
		return false
	end
	if typeof(newproxy) ~= "function" then
		return true
	end
	local fake = newproxy(true)
	local touched = 0
	local mt = getmetatable(fake)
	if mt then
		mt.__index = function()
			touched += 1
		end
		mt.__newindex = function()
			touched += 1
		end
		mt.__tostring = function()
			touched += 1
			return "x"
		end
		mt.__metatable = "locked"
	end
	local okReject = pcall(overlapDispatch, fake)
	return (not okReject) and touched == 0
end

local function failClosed()
	cfg.hitboxEnabled = false
	cfg.infStamina = false
	disarmHitbox()
	disarmStamina()
	clearOverlays()
	if hitboxToggle and typeof(hitboxToggle.Set) == "function" then
		pcall(function()
			hitboxToggle:Set(false)
		end)
	end
	if staminaToggle and typeof(staminaToggle.Set) == "function" then
		pcall(function()
			staminaToggle:Set(false)
		end)
	end
end

local okProbeAtLoad, probePassAtLoad = pcall(probeSelfTest)
if not okProbeAtLoad or not probePassAtLoad then
	safetyLocked = true
	warn("[Match] Probe check failed - features locked")
end

task.spawn(function()
	while S.runId == runId do
		task.wait(3)
		if S.runId ~= runId then
			break
		end
		if hitboxArmed or staminaArmed then
			local ok, pass = pcall(probeSelfTest)
			if not ok or not pass then
				warn("[Match] Probe check failed - features disabled")
				failClosed()
			end
		end
	end
end)

-- The server can push ForceSprintStop; replace the single handler slot after
-- DrainStarted (the game registers its own only on the first sprint). With
-- the feature off, call the same public Stamina.stop() the game's callback
-- called, so normal behaviour is unchanged.
local stamRunId = S.runId
local okDrain, drainConn = pcall(function()
	return Stamina.DrainStarted:Connect(function()
		task.defer(function()
			if S.runId ~= stamRunId then
				return
			end
			pcall(function()
				NetStamina.ForceSprintStop.On(function()
					if not cfg.infStamina then
						Stamina.stop()
					end
				end)
			end)
		end)
	end)
end)
if okDrain and drainConn then
	table.insert(S.conns, drainConn)
end

--// ---------------------------------------------------------------- overlay loop
local loopConn
loopConn = RunService.RenderStepped:Connect(function()
	if S.runId ~= runId then
		loopConn:Disconnect()
		return
	end
	if next(visByLimb) then
		syncOverlays()
		sweepOverlays()
	end
end)
table.insert(S.conns, loopConn)

--// ---------------------------------------------------------------- Rayfield UI
getgenv().RAYFIELD_SECURE = true
local okLib, Rayfield = pcall(function()
	return loadstring(game:HttpGet("https://sirius.menu/gen2"))()
end)
if not okLib or typeof(Rayfield) ~= "table" then
	warn("[Match] UI library unavailable")
	teardown()
	return
end

window = Rayfield:CreateWindow({
	name = "Plasma Hub",
	showName = "Plasma Hub", -- collapsed view otherwise falls back to the library's own name
	subtitle = "lite",
	sidebarLayout = true,
	configuration = {
		autoSave = true,
		autoLoad = true,
		fileName = "PlasmaHubLite",
	},
})
S.win = window

-- HITBOX TAB ------------------------------------------------------------
local tabHit = window:CreateTab({ name = "Hitbox" })

tabHit:CreateDivider({ text = "Hitbox" })

hitboxToggle = tabHit:CreateToggle({
	name = "Hitbox Expander",
	flag = "PH_HitboxEnabled",
	value = cfg.hitboxEnabled,
	callback = function(v)
		if cfg.hitboxEnabled == v then
			return
		end
		cfg.hitboxEnabled = v
		if v then
			if safetyLocked or not armHitbox() or not probeSelfTest() then
				cfg.hitboxEnabled = false
				disarmHitbox()
				if typeof(hitboxToggle.Set) == "function" then
					pcall(function()
						hitboxToggle:Set(false)
					end)
				end
				warn("[Match] Hitbox locked - probe check failed")
			end
		else
			disarmHitbox()
		end
	end,
})

tabHit:CreateDropdown({
	name = "Expander Method",
	description = "Method 1 expands your limbs. Method 2 expands the ball.",
	options = {
		"Method 1 - Humanoid",
		"Method 2 - Ball",
	},
	value = cfg.hitboxMethod == "ball" and "Method 2 - Ball" or "Method 1 - Humanoid",
	flag = "PH_HitboxMethod",
	callback = function(choice)
		cfg.hitboxMethod = choice == "Method 2 - Ball" and "ball" or "humanoid"
	end,
})

tabHit:CreateSlider({
	name = "Size Multiplier",
	range = { 1, 10 },
	increment = 0.25,
	value = cfg.hitboxMult,
	suffix = "x",
	flag = "PH_HitboxMult",
	callback = function(v)
		cfg.hitboxMult = v
	end,
})

tabHit:CreateDivider({ text = "Transparency" })

tabHit:CreateToggle({
	name = "Show Hitbox Overlay",
	flag = "PH_HitboxVis",
	value = cfg.hitboxVis,
	callback = function(v)
		cfg.hitboxVis = v
	end,
})

tabHit:CreateSlider({
	name = "Overlay Transparency",
	range = { 0, 0.95 },
	increment = 0.05,
	value = cfg.hitboxVisAlpha,
	flag = "PH_HitboxVisAlpha",
	callback = function(v)
		cfg.hitboxVisAlpha = v
	end,
})

tabHit:CreateColorPicker({
	name = "Overlay Color",
	color = cfg.hitboxVisColor,
	flag = "PH_HitboxVisColor",
	callback = function(color)
		cfg.hitboxVisColor = color
	end,
})

-- MOVEMENT TAB ----------------------------------------------------------
local tabMov = window:CreateTab({ name = "Movement" })

tabMov:CreateDivider({ text = "Stamina" })

staminaToggle = tabMov:CreateToggle({
	name = "Infinite Stamina",
	flag = "PH_InfStamina",
	value = cfg.infStamina,
	callback = function(v)
		if cfg.infStamina == v then
			return
		end
		cfg.infStamina = v
		if v then
			if safetyLocked or not armStamina() or not probeSelfTest() then
				cfg.infStamina = false
				disarmStamina()
				if typeof(staminaToggle.Set) == "function" then
					pcall(function()
						staminaToggle:Set(false)
					end)
				end
				warn("[Match] Infinite stamina locked - probe check failed")
			end
		else
			disarmStamina()
		end
	end,
})

tabMov:CreateDivider({ text = "Session" })

tabMov:CreateButton({
	name = "Unload Hub",
	callback = function()
		teardown()
	end,
})

tabMov:CreateText({
	name = "Plasma Hub Lite - v2",
})
