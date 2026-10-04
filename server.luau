--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local DataStoreService = game:GetService("DataStoreService")

local Config = require(script.Parent.Config)
local SaveManager = require(script.Parent.SaveManager)

local server = {}
local playerDataStore: DataStore
local sessionCache: { [Player]: { Data: table, IsLoaded: boolean, SessionId: string } } = {}
local listeners: { [Player]: { (key: string, value: any) -> () } } = {}
local fetchedPlayers: { [Player]: boolean } = {}
local loadFailures: { [Player]: boolean } = {}
local dataRemote: RemoteEvent
local function getLockTimeout(): number
	return math.max(Config.SessionLockTimeout or 120, (Config.AutoSaveInterval or 300) + (Config.AutoSaveStagger or 1) * Players.MaxPlayers + 60)
end

local function getRemote(): RemoteEvent
	local remote = ReplicatedStorage:FindFirstChild("DataSystemSync") :: RemoteEvent?
	if not remote then
		remote = Instance.new("RemoteEvent")
		remote.Name = "DataSystemSync"
		remote.Parent = ReplicatedStorage
	end
	return remote
end

local function deepCopy(original: any): any
	if type(original) ~= "table" then
		return original
	end
	local copy = {}
	for k, v in pairs(original) do
		copy[deepCopy(k)] = deepCopy(v)
	end
	return copy
end

local function reconcile(target: table, template: table)
	for k, v in pairs(template) do
		if target[k] == nil then
			target[k] = deepCopy(v)
		elseif type(v) == "table" and type(target[k]) == "table" then
			reconcile(target[k], v)
		end
	end
end

local function migrate(data: table)
	if type(data._Metadata) ~= "table" then
		data._Metadata = {}
	end
	local targetVersion = (Config.template._Metadata and Config.template._Metadata.Version) or 1
	local version = tonumber(data._Metadata.Version) or 1
	while version < targetVersion do
		local migration = Config.Migrations and Config.Migrations[version]
		if type(migration) ~= "function" then
			return false, string.format("Missing migration from version %d", version)
		end
		local ok, migrated = pcall(migration, data)
		if not ok then
			return false, migrated
		end
		if type(migrated) == "table" then
			data = migrated
		end
		version += 1
		data._Metadata = if type(data._Metadata) == "table" then data._Metadata else {}
		data._Metadata.Version = version
	end
	return true, data
end

function server.Configure(customConfig: table)
	for key, value in pairs(customConfig) do
		if typeof(value) == "table" and typeof(Config[key]) == "table" then
			for subKey, subValue in pairs(value) do
				Config[key][subKey] = subValue
			end
		else
			Config[key] = value
		end
	end
end

function server.WaitForProfile(player: Player)
	while player.Parent and not (sessionCache[player] and sessionCache[player].IsLoaded) and not loadFailures[player] do
		task.wait()
	end
	if not player.Parent or loadFailures[player] then
		return nil
	end
	return server.getProfile(player)
end

function server.Init(customConfig: table?)
	if customConfig then
		server.Configure(customConfig)
	end
	playerDataStore = DataStoreService:GetDataStore(Config.DataStoreName or "PlayerData")
	dataRemote = getRemote()

	dataRemote.OnServerEvent:Connect(function(player, action)
		if action == "Fetch" and not fetchedPlayers[player] then
			local session = sessionCache[player]
			if session and session.IsLoaded then
				fetchedPlayers[player] = true
				dataRemote:FireClient(player, "InitSync", session.Data)
			end
		end
	end)

	Players.PlayerRemoving:Connect(function(player)
		fetchedPlayers[player] = nil
		local session = sessionCache[player]
		if session and session.IsLoaded then
			local ok, err = SaveManager.SaveAsync(
				playerDataStore,
				"Player_" .. player.UserId,
				session.Data,
				session.SessionId,
				getLockTimeout(),
				Config.MaxRetries or 3,
				true
			)
			if not ok then
				warn("[DataSystem] Failed to save/release session for " .. player.Name .. ": " .. tostring(err))
			end
		end
		sessionCache[player] = nil
		listeners[player] = nil
		loadFailures[player] = nil
	end)

	game:BindToClose(function()
		SaveManager.SetClosing(true)
		local pendingSaves = 0
		for _, player in ipairs(Players:GetPlayers()) do
			local session = sessionCache[player]
			if session and session.IsLoaded then
				pendingSaves += 1
				task.spawn(function()
					local ok, err = SaveManager.SaveAsync(
						playerDataStore,
						"Player_" .. player.UserId,
						session.Data,
						session.SessionId,
						getLockTimeout(),
						Config.MaxRetries or 3,
						true
					)
					if not ok then
						warn("[DataSystem] Shutdown save failed for " .. player.Name .. ": " .. tostring(err))
					end
					pendingSaves -= 1
				end)
			end
		end
		local start = os.clock()
		while pendingSaves > 0 and os.clock() - start < 25 do
			task.wait(0.1)
		end
	end)

	Players.PlayerAdded:Connect(function(player)
		task.spawn(server.LoadPlayer, player)
	end)
	for _, player in ipairs(Players:GetPlayers()) do
		if not sessionCache[player] then
			task.spawn(server.LoadPlayer, player)
		end
	end

	task.spawn(function()
		while true do
			task.wait(Config.AutoSaveInterval or 300)
			local activePlayers = Players:GetPlayers()
			for _, player in ipairs(activePlayers) do
				local session = sessionCache[player]
				if session and session.IsLoaded then
					task.spawn(function()
						local ok, err = SaveManager.SaveAsync(
							playerDataStore,
							"Player_" .. player.UserId,
							session.Data,
							session.SessionId,
							getLockTimeout(),
							Config.MaxRetries or 3,
							false
						)
						if not ok then
							warn("[DataSystem] Autosave failed for " .. player.Name .. ": " .. tostring(err))
						end
					end)
				end
				task.wait(Config.AutoSaveStagger or 1)
			end
		end
	end)
end

function server.LoadPlayer(player: Player)
	local key = "Player_" .. player.UserId
	local sessionId = SaveManager.NewSessionId()
	local lockTimeout = getLockTimeout()
	local retryInterval = Config.RejoinCooldown or 5
	local lockSuccess, rawData

	while player.Parent and not lockSuccess do
		lockSuccess, rawData = SaveManager.AcquireSessionAsync(
			playerDataStore, key, sessionId, deepCopy(Config.template), lockTimeout, Config.MaxRetries or 3
		)
		if lockSuccess then
			break
		end
		if rawData ~= "Profile is locked by another server" then
			warn("[DataSystem] Could not load profile for " .. player.Name .. ": " .. tostring(rawData))
			loadFailures[player] = true
			return
		end
		task.wait(retryInterval)
	end
	if not lockSuccess or not player.Parent then
		return
	end

	local data = if type(rawData) == "table" then rawData else deepCopy(Config.template)
	local migrationOk, migrationResult = migrate(data)
	if not migrationOk then
		warn("[DataSystem] Migration failed for " .. player.Name .. ": " .. tostring(migrationResult))
		SaveManager.SaveAsync(playerDataStore, key, data, sessionId, lockTimeout, Config.MaxRetries or 3, true)
		loadFailures[player] = true
		return
	end
	data = migrationResult
	reconcile(data, Config.template)
	data._Metadata.SessionId = sessionId
	data._Metadata.LockExpiresAt = os.time() + lockTimeout

	sessionCache[player] = { Data = data, IsLoaded = true, SessionId = sessionId }
	loadFailures[player] = nil
	if dataRemote and player.Parent then
		dataRemote:FireClient(player, "InitSync", data)
	end
end

function server.SavePlayer(player: Player)
	local session = sessionCache[player]
	if session and session.IsLoaded then
		task.spawn(function()
			local ok, err = SaveManager.SaveAsync(
				playerDataStore,
				"Player_" .. player.UserId,
				session.Data,
				session.SessionId,
				getLockTimeout(),
				Config.MaxRetries or 3,
				false
			)
			if not ok then
				warn("[DataSystem] Save failed for " .. player.Name .. ": " .. tostring(err))
			end
		end)
	end
end

function server.getProfile(player: Player)
	local init = script.Parent
	local DataSystem = require(init)
	return DataSystem.CreateProxy(function()
		local session = sessionCache[player]
		return session and session.Data or Config.template
	end, function(valOrTransform)
		local session = sessionCache[player]
		if not session or not session.IsLoaded then
			return
		end
		if typeof(valOrTransform) == "function" then
			session.Data = valOrTransform(session.Data)
		else
			session.Data = valOrTransform
		end
		if dataRemote then
			dataRemote:FireClient(player, "InitSync", session.Data)
		end
		if listeners[player] then
			for _, callback in ipairs(listeners[player]) do
				task.spawn(callback, session.Data)
			end
		end
	end, function(callback)
		if not listeners[player] then
			listeners[player] = {}
		end
		table.insert(listeners[player], callback)
		return {
			Disconnect = function()
				local idx = table.find(listeners[player], callback)
				if idx then
					table.remove(listeners[player], idx)
				end
			end,
		}
	end)
end

server.GetSession = server.getProfile
return setmetatable(server, {
	__call = function(_, player: Player)
		return server.getProfile(player)
	end,
	__index = function(t, key)
		if typeof(key) == "Instance" and key:IsA("Player") then
			return server.getProfile(key)
		end
		return rawget(t, key)
	end,
})





