export type Disconnectable = {
	Disconnect: (self: Disconnectable) -> (),
}

export type Signal<T> = {
	Connect: (self: Signal<T>, callback: (newValue: T) -> ()) -> Disconnectable,
}

export type ArrayProxy<T> = {
	insert: (self: ArrayProxy<T>, item: T, index: number?) -> (),
	remove: (self: ArrayProxy<T>, index: number?) -> T?,
	changed: Signal<{ T }>,
} & (() -> { T })

export type DataProxy<T> = T & {
	changed: Signal<T>,
}

return nil
