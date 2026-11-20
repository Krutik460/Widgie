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

## Vocabulary

A look is a tree of nodes. Every node is an object with a `type`, its props, and for containers a `children` list:

```
{ "type": "hstack", "spacing": 6, "children": [ { "type": "text", "value": "Hi" }, { "type": "spacer" } ] }
```

Unknown node types and unknown props are errors. All sizes are in points. The widget is 158 x 158 points in the `small` family and 338 x 158 in `medium`. The root node is centered in the widget and gets no automatic padding. The widget's corners are rounded for you.

### Node types

| type | what it is | own props |
|---|---|---|
| `vstack` | children top to bottom | `spacing`, `align` (leading, center, trailing), `children` |
| `hstack` | children left to right | `spacing`, `align` (top, center, bottom, firstBaseline), `children` |
| `zstack` | children layered back to front | `align` (an alignment name), `children` |
| `spacer` | flexible empty space inside a stack | `minLength` |
| `text` | a run of text | `value`, `size` (default 15), `weight`, `design`, `italic`, `color`, `lineLimit`, `minScale`, `align`, `strikethrough`, `kerning` |
| `symbol` | an SF Symbol icon | `name`, `size` (default 17), `weight`, `color` |
| `rect` | rectangle, fills the space it is given | `cornerRadius`, `fill`, `stroke`, `trimFrom`, `trimTo` |
| `circle` | circle, fits the space it is given | `fill`, `stroke`, `trimFrom`, `trimTo` |
| `capsule` | pill shape, fills the space it is given | `fill`, `stroke`, `trimFrom`, `trimTo` |
| `ellipse` | ellipse, fills the space it is given | `fill`, `stroke`, `trimFrom`, `trimTo` |
| `path` | custom shape | `d` (SVG path data), `viewBox` (`[minX, minY, width, height]`), `fill`, `stroke`, `trimFrom`, `trimTo` |
| `button` | makes its children tappable; looks exactly like its children, layered as in a zstack | `action` (an action id), `rowId` (optional, the id of the data row the tap is about), `children` |

Text details: `weight` is one of ultraLight, thin, light, regular, medium, semibold, bold, heavy, black. `design` is one of default, serif, rounded, monospaced. `align` is leading, center, or trailing and affects multi-line text. `lineLimit` is the maximum number of lines. `minScale` (0 to 1) lets text shrink to fit. `italic` and `strikethrough` are true or false. Text and symbols are black unless you set `color`.

Shape details: shapes have no size of their own, so give them a `frame` or let a parent size them. `fill` is a color or gradient (black when there is neither fill nor stroke). `stroke` is `{ "color": color or gradient, "width": number, "cap": "butt" or "round" }` and is drawn inside the shape's bounds. `trimFrom` and `trimTo` (0 to 1) draw only part of the outline. On a circle the outline starts at 3 o'clock and runs clockwise, so add `"rotation": -90` to start at the top. A `path` is scaled to fit its frame, keeping the aspect ratio of its `viewBox`.

### Common props (any node)

Props are applied in this fixed order, whatever order you write them in:

1. `aspectRatio`: width divided by height, fitted.
2. `padding`: a number, or an object with any of `top`, `bottom`, `leading`, `trailing`, `horizontal`, `vertical`.
3. `frame`: an object with any of `width`, `height`, `minWidth`, `maxWidth`, `minHeight`, `maxHeight`, `alignment`. Values are numbers. `maxWidth` and `maxHeight` also accept the string `"infinity"` to fill the available space. `alignment` is an alignment name and places the content inside the frame.
4. `background`: a color, a gradient, or a node drawn behind.
5. `overlay`: a node drawn on top.
6. `cornerRadius`: clips to rounded corners (on a `rect` it rounds the shape itself). `clip`: clips to `rect`, `circle`, `capsule`, or `ellipse`.
7. `mask`: a node. This node shows only where the mask is opaque.
8. `opacity`: 0 to 1.
9. `shadow`: `{ "color": color, "radius": number, "x": number, "y": number }`.
10. `blur`: a radius.
11. `scale`: a number, or `{ "x": number, "y": number }`.
12. `rotation`: degrees clockwise.
13. `offset`: `{ "x": number, "y": number }`.

To apply props in another order, wrap the node in a `zstack` and put the later props on the wrapper.

The root node also takes `widgetBackground` (a color, gradient, or node) that fills the whole widget. Without it the widget is white.

### Values

- Colors are hex strings, `"#RRGGBB"` or `"#RRGGBBAA"` (alpha last). There are no color names.
- Gradients are `{ "gradient": "linear", "stops": [...], "from": point, "to": point }`, `{ "gradient": "radial", "stops": [...], "center": point, "startRadius": number, "endRadius": number }`, or `{ "gradient": "angular", "stops": [...], "center": point, "startAngle": degrees, "endAngle": degrees }`. `stops` is a list of colors spaced evenly, or a list of `{ "color": color, "at": 0 to 1 }`. A point is an alignment name or `[x, y]` with each value from 0 to 1.
- Alignment names are topLeading, top, topTrailing, leading, center, trailing, bottomLeading, bottom, bottomTrailing.
- SF Symbol names must be real ones, for example `plus`, `minus`, `checkmark`, `flame.fill`, `drop.fill`, `circle`, `checkmark.circle.fill`, `star.fill`.

### Limits

There is no scrolling, no text input, no images, no animation, and no custom fonts. Whatever does not fit is cut off, so size things for 158 points of height.

## Worked example

A reading tracker. Its data looks like this, and it has one action, `logPages`.

```json
{
  "title": "Dune",
  "pagesRead": 180,
  "pagesGoal": 300,
  "sessions": [
    { "day": "M", "pages": 30 },
    { "day": "T", "pages": 12 },
    { "day": "W", "pages": 0 },
    { "day": "T", "pages": 40 },
    { "day": "F", "pages": 22 }
  ]
}
```

The look shows the title, a percentage that turns into a seal when the goal is reached, a progress bar whose width and color follow the data, one bar per reading session, an extra line of text in the medium family, and a button.

```json
{
  "type": "vstack",
  "align": "leading",
  "spacing": 8,
  "padding": 14,
  "frame": { "maxWidth": "infinity", "maxHeight": "infinity", "alignment": "topLeading" },
  "widgetBackground": { "gradient": "linear", "stops": ["#1B2A41", "#0C1821"], "from": "top", "to": "bottom" },
  "children": [
    {
      "type": "hstack",
      "spacing": 6,
      "children": [
        { "type": "text", "value": "{{ data.title }}", "size": 17, "weight": "bold", "design": "serif", "color": "#FFFFFF", "lineLimit": 1 },
        { "type": "spacer" },
        {
          "type": "if",
          "test": "{{ data.pagesRead >= data.pagesGoal }}",
          "then": [{ "type": "symbol", "name": "checkmark.seal.fill", "size": 16, "color": "#7AE582" }],
          "else": [{ "type": "text", "value": "{{ round(100 * data.pagesRead / data.pagesGoal) }}%", "size": 13, "weight": "semibold", "color": "#9FB3C8" }]
        }
      ]
    },
    {
      "type": "zstack",
      "align": "leading",
      "children": [
        { "type": "capsule", "fill": "#FFFFFF22", "frame": { "height": 8 } },
        {
          "type": "capsule",
          "fill": "{{ lerpColor('#F4A259', '#7AE582', data.pagesRead / data.pagesGoal) }}",
          "frame": { "width": "{{ (width - 28) * clamp(data.pagesRead / data.pagesGoal, 0, 1) }}", "height": 8 }
        }
      ]
    },
    {
      "type": "if",
      "test": "{{ family == 'medium' }}",
      "then": [{ "type": "text", "value": "{{ data.pagesRead }} of {{ data.pagesGoal }} pages", "size": 12, "color": "#9FB3C8" }]
    },
    {
      "type": "hstack",
      "align": "bottom",
      "spacing": 6,
      "frame": { "maxHeight": "infinity", "alignment": "bottom" },
      "children": [
        {
          "type": "repeat",
          "over": "{{ data.sessions }}",
          "item": "s",
          "index": "i",
          "children": [
            {
              "type": "vstack",
              "spacing": 3,
              "children": [
                {
                  "type": "rect",
                  "cornerRadius": 3,
                  "fill": "{{ i == len(data.sessions) - 1 ? '#7AE582' : '#5C7C99' }}",
                  "frame": { "width": 10, "height": "{{ 4 + 36 * min(s.pages, 40) / 40 }}" }
                },
                { "type": "text", "value": "{{ s.day }}", "size": 9, "color": "#9FB3C8" }
              ]
            }
          ]
        },
        { "type": "spacer" },
        {
          "type": "button",
          "action": "logPages",
          "children": [
            {
              "type": "symbol", "name": "plus", "size": 16, "weight": "bold", "color": "#0C1821",
              "frame": { "width": 34, "height": 34 }, "background": "#7AE582", "clip": "circle"
            }
          ]
        }
      ]
    }
  ]
}
```

---

# Your task

Write the look for this widget.

## Data

The widget's data has these fields:

```
todayCount: number, glasses drunk today
goal: number, the daily goal in glasses
unit: string
last7: list of 7 numbers, glasses per day for the last 7 days, oldest first, today last
```

One sample of the data. The values change over time, and the look must work for any values:

```json
{
  "todayCount": 2,
  "goal": 8,
  "unit": "glasses",
  "last7": [
    6,
    8,
    5,
    7,
    8,
    4,
    2
  ]
}
```

## Actions

- `addGlass`: logs one more glass
- `undoLast`: removes the most recent glass

Use these ids as the `action` of `button` nodes. No other action ids exist.

## Sizes

The same look is drawn in both families: small (158 x 158 points) and medium (338 x 158 points). It must look right in both.

## The look the user asked for

"a glass that fills up with water as I drink, bubbly blue, with a big plus button"

Reply with the look only, as one fenced ```json code block. No explanation before or after.