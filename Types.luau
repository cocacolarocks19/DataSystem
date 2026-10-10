export type Disconnectable = {
	Disconnect: (self: Disconnectable) -> (),
}

export type Signal<T> = {
	Connect: (self: Signal<T>, callback: (newValue: T) -> ()) -> Disconnectable,
}

-- Array helpers are returned as closures, so call them with dot syntax:
-- items.insert(value), items.get(index), items.length().
export type ArrayProxy<T> = {
	insert: (item: T, index: number?) -> number?,
	push: (item: T) -> number?,
	remove: (index: number?) -> T?,
	pop: () -> T?,
	get: (index: number) -> T?,
	set: (index: number, value: T) -> (),
	length: () -> number,
	clear: () -> (),
	changed: Signal<{ T }>,
} & (() -> { T })

export type DataProxy<T> = T & {
	changed: Signal<T>,
}

return nil
