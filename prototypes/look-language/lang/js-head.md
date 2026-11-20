# Widget look language: JavaScript

You describe how a home screen widget looks by writing a JavaScript function. The app calls the function with the widget's current data and draws the tree of nodes it returns. The function is called again after every tap with fresh data, so the look always reflects the data.

## How a JavaScript look works

The look is one JavaScript file that defines `function render(ctx)`. It returns the root node as a plain object.

### ctx

`render` can read `ctx.data` (the widget's data), `ctx.family` (`"small"` or `"medium"`), and `ctx.width` and `ctx.height` (the widget size in points).

### Rules

- `render` must be a pure function of `ctx`. The same input must give the same tree. Do not use `Math.random` or the current time.
- Only standard JavaScript built-ins exist, such as Math, JSON, Array, String, and Object. There is no DOM, no `console`, no network, no timers, and no imports.
- You may define helper functions and constants in the file.
- `render` must finish within 250 ms.

### The returned tree

- The tree must be plain data: objects, arrays, strings, finite numbers, and booleans. An exception, a NaN, or an Infinity is an error.
- A prop whose value is `undefined` or `null` is treated as absent.
- `children` may contain nested arrays, which are flattened, and `null` or `false` entries, which are skipped. So `list.map(...)` and `test && node` both work inside `children`.

There is nothing else. No helper library, no built-in color functions, no state kept between calls.
