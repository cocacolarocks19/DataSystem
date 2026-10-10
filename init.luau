local DataSystem = {}
local Types = require(script.Types)

export type Signal<T> = Types.Signal<T>
export type ArrayProxy<T> = Types.ArrayProxy<T>
export type DataProxy<T> = Types.DataProxy<T>
export type Disconnectable = Types.Disconnectable

DataSystem.server = require(script.server)
DataSystem.client = require(script.client)

local function deepCopy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local copy = {}
	for key, child in pairs(value) do
		copy[deepCopy(key)] = deepCopy(child)
	end
	return copy
end

local function createProxy(getValueFn, setValueFn, subscribeFn)
	local proxy = {}
	local meta = {}

	-- Calling a proxy reads a value or sets it: data.Gold() / data.Gold(100).
	-- Tables are copied so callers cannot mutate the stored profile by reference.
	meta.__call = function(_, newValue)
		if newValue ~= nil then
			local current = getValueFn()
			local resolved
			if typeof(newValue) == "function" then
				resolved = newValue(deepCopy(current))
			else
				resolved = newValue
			end

			if typeof(resolved) == "number" and resolved < 0 then
				warn("[DataSystem] Attempted to set negative value, clamping to 0")
				resolved = 0
			end

			local storedValue = deepCopy(resolved)
			setValueFn(storedValue)
			return deepCopy(storedValue)
		end
		return deepCopy(getValueFn())
	end

	meta.__len = function()
		local current = getValueFn()
		return type(current) == "table" and #current or 0
	end

	-- Luau generalized iteration: for index, value in data.Inventory do
	-- Iterate over a snapshot so callers cannot mutate stored tables by reference.
	meta.__iter = function()
		local current = getValueFn()
		local snapshot = type(current) == "table" and deepCopy(current) or {}
		local arrayLength = #snapshot
		if arrayLength > 0 then
			local index = 0
			return function()
				index += 1
				if index <= arrayLength then
					return index, snapshot[index]
				end
			end
		end
		return next, snapshot, nil
	end

	meta.__index = function(_, key)
		if key == "changed" then
			return {
				Connect = function(_, callback)
					return subscribeFn(callback)
				end,
			}
		elseif key == "length" then
			return function()
				local current = getValueFn()
				return type(current) == "table" and #current or 0
			end
		elseif key == "get" then
			return function(index: number)
				local current = getValueFn()
				if type(current) == "table" and typeof(index) == "number" then
					return deepCopy(current[index])
				end
				return nil
			end
		elseif key == "set" then
			return function(index: number, value: any)
				local current = getValueFn()
				if type(current) ~= "table" or typeof(index) ~= "number" or index % 1 ~= 0 or index < 1 or index > #current then
					warn("[DataSystem] Array set index is out of range")
					return
				end
				local updated = table.clone(current)
				updated[index] = deepCopy(value)
				setValueFn(updated)
			end
		elseif key == "insert" or key == "push" then
			return function(item, index: number?)
				local current = getValueFn()
				if type(current) ~= "table" then
					warn("[DataSystem] insert/push can only be used on array data")
					return nil
				end
				local updated = table.clone(current)
				if key == "push" or index == nil then
					table.insert(updated, deepCopy(item))
				else
					if typeof(index) ~= "number" or index % 1 ~= 0 or index < 1 or index > #updated + 1 then
						warn("[DataSystem] Array insert index is out of range")
						return nil
					end
					table.insert(updated, index, deepCopy(item))
				end
				setValueFn(updated)
				return #updated
			end
		elseif key == "remove" or key == "pop" then
			return function(index: number?)
				local current = getValueFn()
				if type(current) ~= "table" then
					warn("[DataSystem] remove/pop can only be used on array data")
					return nil
				end
				local removeIndex = if key == "pop" then #current else (index or #current)
				if typeof(removeIndex) ~= "number" or removeIndex % 1 ~= 0 or removeIndex < 1 or removeIndex > #current then
					return nil
				end
				local updated = table.clone(current)
				local removed = table.remove(updated, removeIndex)
				setValueFn(updated)
				return deepCopy(removed)
			end
		elseif key == "clear" then
			return function()
				local current = getValueFn()
				if type(current) == "table" then
					setValueFn({})
				end
			end
		end

		-- Child property/index proxy. False values must remain readable.
		return createProxy(function()
			local current = getValueFn()
			if type(current) == "table" then
				return current[key]
			end
			return nil
		end, function(value)
			local current = getValueFn()
			if type(current) == "table" then
				local updated = table.clone(current)
				if typeof(value) == "function" then
					updated[key] = deepCopy(value(deepCopy(current[key])))
				else
					updated[key] = deepCopy(value)
				end
				setValueFn(updated)
			end
		end, function(callback)
			local lastValue = nil
			return subscribeFn(function(newTable)
				if type(newTable) == "table" then
					local childValue = newTable[key]
					if childValue ~= lastValue then
						lastValue = childValue
						callback(deepCopy(childValue))
					end
				end
			end)
		end)
	end

	return setmetatable(proxy, meta)
end

function DataSystem.CreateProxy(getValueFn, setValueFn, subscribeFn)
	return createProxy(getValueFn, setValueFn, subscribeFn)
end

return DataSystem




