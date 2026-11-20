# Widget look language: template

You describe how a home screen widget looks by writing a JSON template. The app evaluates the template against the widget's current data and draws the resulting tree of nodes. The template is evaluated again after every tap with fresh data, so the look always reflects the data.

## How a template look works

The look is one JSON document, the root node. It must be strict JSON: double quotes, no comments, no trailing commas.

### Names

Expressions can read `data` (the widget's data), `family` (`"small"` or `"medium"`), `width` and `height` (the widget size in points), and any names introduced by an enclosing `repeat`.

### Bindings

Any string prop may contain `{{ expression }}`.

- Mixed with other text, the result is inserted as text: `"value": "{{ data.count }} of {{ data.goal }}"`.
- When the whole string is a single `{{ expression }}`, the prop gets the expression's own type. Use this for numbers, booleans, and colors: `"opacity": "{{ item.done ? 0.4 : 1 }}"`.
- A prop whose value is `null` is treated as absent.

### Expressions

- Literals: numbers, strings in single quotes, `true`, `false`, `null`.
- Paths: `data.items[0].title`, `data.last7[i]`. A missing field or an out of range index is an error.
- Operators: `+ - * / %`, `== != < <= > >=`, `&& || !`, `test ? a : b`, and parentheses. `+` also joins strings.
- Functions: `min(a, b, ...)`, `max(a, b, ...)`, `round(x)`, `floor(x)`, `ceil(x)`, `abs(x)`, `clamp(x, lo, hi)`, `len(listOrString)`, `str(x)`, and `lerpColor(colorA, colorB, t)`, which blends two hex colors with t from 0 to 1.

There is nothing else. No variables, no assignment, no functions of your own, no method calls.

### repeat

`{ "type": "repeat", "over": "{{ list }}", "item": "name", "index": "name", "children": [...] }` emits its children once per element, in place, into the parent's children. `over` is a data list or `range(n)`, the numbers 0 to n - 1. `item` and `index` name the element and its position for the expressions inside (the defaults are `item` and `index`). Repeats can nest.

### if

`{ "type": "if", "test": "{{ expression }}", "then": [...], "else": [...] }` emits the `then` nodes when the test is true and the `else` nodes otherwise, in place. `else` is optional.

`repeat` and `if` are allowed anywhere a child node is allowed.
