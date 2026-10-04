--!strict
local HttpService = game:GetService("HttpService")

local SaveManager = {}
local activeSaves = 0
local shutdownInProgress = false

function SaveManager.SetClosing(status: boolean)
	shutdownInProgress = status
end

function SaveManager.GetActiveCount(): number
	return activeSaves
end

function SaveManager.NewSessionId(): string
	return game.JobId .. ":" .. HttpService:GenerateGUID(false)
end

function SaveManager.AcquireSessionAsync(dataStore: DataStore, key: string, sessionId: string, template: any, lockTimeout: number, maxRetries: number): (boolean, any)
	local attempt = 0
	local lastError = nil
	while attempt < maxRetries do
		attempt += 1
		local success, result = pcall(function()
			return dataStore:UpdateAsync(key, function(oldData)
				local data = if type(oldData) == "table" then oldData else template
				local metadata = if type(data._Metadata) == "table" then data._Metadata else {}
				local lockOwner = metadata.SessionId
				local lockExpiry = tonumber(metadata.LockExpiresAt) or 0
				if lockOwner and lockOwner ~= sessionId and lockExpiry > os.time() then
					return nil
				end

				local updated = table.clone(data)
				local updatedMetadata = table.clone(metadata)
				updatedMetadata.SessionId = sessionId
				updatedMetadata.LockExpiresAt = os.time() + lockTimeout
				updated._Metadata = updatedMetadata
				return updated
			end)
		end)
		if success then
			if result ~= nil then
				return true, result
			end
			return false, "Profile is locked by another server"
		end
		lastError = result
		if attempt < maxRetries and not shutdownInProgress then
			task.wait(math.min(2 ^ (attempt - 1), 10))
		end
	end
	return false, lastError
end

function SaveManager.SaveAsync(dataStore: DataStore, key: string, data: any, sessionId: string, lockTimeout: number, maxRetries: number, releaseLock: boolean?): (boolean, any)
	activeSaves += 1
	local success = false
	local result = nil
	local attempt = 0
	local backoff = 1

	while attempt < maxRetries do
		attempt += 1
		success, result = pcall(function()
			return dataStore:UpdateAsync(key, function(oldData)
				if type(oldData) ~= "table" or type(oldData._Metadata) ~= "table" then
					return nil
				end
				if oldData._Metadata.SessionId ~= sessionId then
					return nil
				end

				local updated = table.clone(data)
				local sourceMetadata = if type(data._Metadata) == "table" then data._Metadata else oldData._Metadata
				local metadata = table.clone(sourceMetadata)
				metadata.LastSaveTime = os.time()
				metadata.SessionId = if releaseLock then nil else sessionId
				metadata.LockExpiresAt = if releaseLock then nil else os.time() + lockTimeout
				updated._Metadata = metadata
				return updated
			end)
		end)
		if success then
			if result ~= nil then
				activeSaves -= 1
				return true, result
			end
			result = "Session lock was lost; save was rejected"
			break
		end

		if attempt < maxRetries then
			if not shutdownInProgress then
				task.wait(backoff)
				backoff = math.min(backoff * 2, 10)
			else
				task.wait(0.5)
			end
		end
	end

	activeSaves -= 1
	return false, result
end

return SaveManager


