<!-- Tests/LookTests/ReferenceTests.swift runs every js block below against the example widget and the example
ctx on this page, in both sizes. A js block followed by a text block must fail with exactly the line in the text
block. The test also checks the node, common prop, and font tables against the validator. -->

# Widget look language

A widget's look is JavaScript. It defines `function render(ctx)`, which receives the widget's data and returns a tree of nodes. The app draws that tree on the home screen. It calls `render` again after every tap and at every new day, so the look always shows the current data.

## How a look works

The look is one script. It may define constants and helper functions, and it must define `render(ctx)` at the top level. `render` returns the root node as a plain object.

### ctx

`render` receives one argument.

| Key | Holds |
|---|---|
| `ctx.data` | One key per query id of the widget. `count`, `sum`, and `streak` give a number. `latest` gives a row or `null`. `list` gives a list of rows. `daily` gives a list of `{ date, weekday, count }`, oldest first and today last, with `sum` added when it sums a field. |
| `ctx.family` | `"small"` or `"medium"`. |
| `ctx.width`, `ctx.height` | The widget size in points: 158 x 158 for small and 338 x 158 for medium on a typical phone. Other phones differ by a few points, so read these instead of assuming them. |
| `ctx.today` | `{ date, weekday, week }`. `date` is today as `"2026-11-18"`, `weekday` is `"Mon"` to `"Sun"`, and `week` is the seven dates of the current week, first day first. |

A row is `{ id, day, daysAgo, ...fields }`. `id` is a string that a button passes back to say which row it is about. `day` is the date the row was written and `daysAgo` is how many days ago that was. Every field of the row's table is present. A bool field with no value is `false`, and any other field with no value is `null`.

This is the `ctx` of the example widget below, in the small size:

```json
{
  "data": {
    "pagesToday": 24,
    "last": { "id": "0193f4c2-7a1e-7000-8000-00000000a012", "day": "2026-11-18", "daysAgo": 0, "pages": 12 },
    "books": [
      { "id": "0193f4c2-7a1e-7000-8000-00000000b001", "day": "2026-11-02", "daysAgo": 16, "title": "Dune", "done": false },
      { "id": "0193f4c2-7a1e-7000-8000-00000000b002", "day": "2026-11-09", "daysAgo": 9, "title": "The Left Hand of Darkness", "done": false },
      { "id": "0193f4c2-7a1e-7000-8000-00000000b003", "day": "2026-11-15", "daysAgo": 3, "title": "Piranesi", "done": false }
    ],
    "week": [
      { "date": "2026-11-12", "weekday": "Thu", "count": 2 },
      { "date": "2026-11-13", "weekday": "Fri", "count": 0 },
      { "date": "2026-11-14", "weekday": "Sat", "count": 3 },
      { "date": "2026-11-15", "weekday": "Sun", "count": 1 },
      { "date": "2026-11-16", "weekday": "Mon", "count": 2 },
      { "date": "2026-11-17", "weekday": "Tue", "count": 0 },
      { "date": "2026-11-18", "weekday": "Wed", "count": 2 }
    ]
  },
  "family": "small",
  "width": 158,
  "height": 158,
  "today": {
    "date": "2026-11-18",
    "weekday": "Wed",
    "week": ["2026-11-16", "2026-11-17", "2026-11-18", "2026-11-19", "2026-11-20", "2026-11-21", "2026-11-22"]
  }
}
```

### Rules

- `render` must be a pure function of `ctx`. The same `ctx` must give the same tree. `Math.random()`, `Date.now()`, `Date()`, and `new Date()` with no arguments fail the look, even inside `try`. Take the date from `ctx.today`. `new Date("2026-11-18")` and other dates built from values in `ctx` are allowed.
- Only standard JavaScript built-ins exist, such as `Math`, `JSON`, `Array`, `String`, `Number`, and `Object`. There is no DOM, no `console`, no network, no timers, and no imports.
- `render` must finish within 100 ms. A loop that never ends fails the look.
- The tree is plain data: objects, lists, strings, finite numbers, and booleans. A function, a `NaN`, or an `Infinity` anywhere in it is an error.
- A prop whose value is `null` or `undefined` counts as absent.
- `children` may hold nested lists, which are flattened, and `null`, `undefined`, `false`, `0`, and `""`, which are skipped. So `list.map(...)` and `test && node` both work inside `children`.

## The example widget

The examples on this page belong to this widget: a reading log with a list of books. Its look is whichever example you are reading.

```json
{
  "name": "Reading",
  "tables": {
    "sessions": { "fields": { "pages": "number" } },
    "books": { "fields": { "title": "text", "done": "bool" } }
  },
  "queries": {
    "pagesToday": { "sum": "sessions.pages", "window": "today" },
    "last": { "latest": "sessions", "window": "today" },
    "books": { "list": "books", "where": { "done": false }, "window": "all", "sort": "oldest", "limit": 5 },
    "week": { "daily": "sessions", "days": 7 }
  },
  "actions": {
    "log": { "insert": "sessions", "values": { "pages": 10 } },
    "undo": { "delete": "sessions" },
    "finish": { "toggle": "books.done" },
    "addBook": { "form": "books", "fields": ["title"], "prompt": "New book" }
  },
  "assets": {
    "cover": { "about": "a painted book cover: a lighthouse on a cliff at dusk" }
  }
}
```

## Nodes

A look is a tree of nodes. Every node is an object with a `type` and its props. A container also has `children`.

```js
function render(ctx) {
  return {
    type: 'vstack',
    spacing: 4,
    widgetBackground: '#1B2A41',
    children: [
      { type: 'text', value: 'Reading', size: 13, weight: 'semibold', color: '#9FB3C8' },
      { type: 'text', value: ctx.data.pagesToday + ' pages', size: 28, weight: 'bold', color: '#FFFFFF' },
    ],
  };
}
```

The root node is centered in the widget and is offered the whole widget. It gets no automatic padding. The widget's corners are rounded for you. Unknown types and unknown props are errors.

### Node types

| Type | What it is | Own props |
|---|---|---|
| `vstack` | children top to bottom | `spacing`, `align`, `children` |
| `hstack` | children left to right | `spacing`, `align`, `children` |
| `zstack` | children layered back to front | `align`, `children` |
| `spacer` | flexible empty space inside a stack | `minLength` |
| `text` | a run of text | `value`, `size`, `weight`, `design`, `italic`, `color`, `lineLimit`, `minScale`, `align`, `strikethrough`, `kerning`, `fontName` |
| `symbol` | an SF Symbol icon | `name`, `size`, `weight`, `color` |
| `rect` | a rectangle that fills the space it is given | `cornerRadius`, `fill`, `stroke`, `trimFrom`, `trimTo` |
| `circle` | a circle that fits the space it is given | `fill`, `stroke`, `trimFrom`, `trimTo` |
| `capsule` | a pill that fills the space it is given | `fill`, `stroke`, `trimFrom`, `trimTo` |
| `ellipse` | an ellipse that fills the space it is given | `fill`, `stroke`, `trimFrom`, `trimTo` |
| `path` | any shape, from SVG path data | `d`, `viewBox`, `fill`, `stroke`, `trimFrom`, `trimTo` |
| `image` | one of the widget's image assets | `asset`, `mode`, `crop`, `saturation`, `brightness`, `contrast` |
| `button` | makes its children tappable and looks exactly like them, layered as in a `zstack` | `action`, `rowId`, `day`, `children` |

Stacks: `spacing` is the gap between children in points. A `vstack` aligns children `leading`, `center` (the default), or `trailing`. An `hstack` aligns them `top`, `center` (the default), `bottom`, or `firstBaseline`. A `zstack` takes any alignment name. A `spacer` takes the free space along its stack and pushes its siblings apart. Give it `minLength: 0` when space is tight, because by default it keeps a few points even when there is no room.

### Text

`value` is a string or a number. `size` is in points (default 15). `weight` is one of `ultraLight`, `thin`, `light`, `regular`, `medium`, `semibold`, `bold`, `heavy`, `black`. `design` is one of `default`, `serif`, `rounded`, `monospaced`. `italic` and `strikethrough` are `true` or `false`. `color` is a hex color (default black). `lineLimit` is the most lines the text may take; past it the text ends in an ellipsis. `minScale` (0.01 to 1) lets the text shrink to that fraction of its size before it wraps or cuts. `align` is `leading` (the default), `center`, or `trailing`, and affects text with more than one line. `kerning` adds points between letters.

Text that shows live data must stay readable at its longest. A count can reach three digits and a title can be long, so give live text a `lineLimit` and a `minScale`, or room to wrap.

### Named fonts

`fontName` sets a font family from this list and replaces `design`. `weight` and `italic` then pick the nearest face the family has; some families have one face. A named font can be wider or taller than the system font at the same `size`, so leave room. Any other name is an error.

| `fontName` | Style |
|---|---|
| `Bradley Hand` | handwriting, a quick pen |
| `Noteworthy` | handwriting, neat notes |
| `Marker Felt` | handwriting, felt marker |
| `Chalkduster` | display, chalk on a blackboard |
| `Snell Roundhand` | script, formal calligraphy |
| `American Typewriter` | typewriter |
| `Rockwell` | slab serif |
| `DIN Condensed` | condensed bold signage |
| `Avenir Next Condensed` | condensed, clean |
| `Futura` | geometric poster type |
| `Copperplate` | engraved small capitals |
| `Didot` | high contrast fashion serif |

```js
function render(ctx) {
  return {
    type: 'vstack', align: 'leading', spacing: 2, padding: 16,
    frame: { maxWidth: 'infinity', maxHeight: 'infinity', alignment: 'bottomLeading' },
    widgetBackground: '#264653',
    children: [
      { type: 'text', value: 'Today I read', size: 15, fontName: 'Noteworthy', color: '#E9C46A' },
      { type: 'text', value: ctx.data.pagesToday + ' pages', size: 34, fontName: 'Didot', weight: 'bold',
        color: '#F4F1EA', lineLimit: 1, minScale: 0.5 },
    ],
  };
}
```

### Symbols

`name` is an SF Symbol name such as `plus`, `minus`, `checkmark`, `checkmark.circle.fill`, `circle`, `flame.fill`, `drop.fill`, `star.fill`, or `book.closed.fill`. A name that does not exist is an error. `size` is in points (default 17), and `weight` and `color` work as on text.

### Shapes

A shape has no size of its own. Give it a `frame` or let its parent size it. A `circle` fits the space it is given; the other shapes fill it.

- `fill` is a color or a gradient. A shape with neither `fill` nor `stroke` is filled black.
- `stroke` is `{ color, width, cap, dash }`. On a `rect`, `circle`, `capsule`, or `ellipse` it is drawn inside the shape's bounds; on a `path` it is centered on the line, so leave half the width as margin. `color` is a color or a gradient. `width` defaults to 1. `cap` is `butt` (the default) or `round`. `dash` is `"dashed"`, `"dotted"` (round dots), or a list of dash and gap lengths such as `[6, 3]`.
- `trimFrom` and `trimTo` (0 to 1) draw only part of the outline. A circle's outline starts at 3 o'clock and runs clockwise, so add `rotation: -90` to start at the top.
- On a `rect`, `cornerRadius` rounds the shape itself.
- A `path` takes SVG path data in `d` (commands M, L, H, V, C, S, Q, T, A, Z, upper case absolute and lower case relative) and `viewBox`, `[minX, minY, width, height]`, the area of the path to show. The path is scaled to fit its frame and keeps the view box's proportions.

```js
const GOAL = 30;

function render(ctx) {
  const progress = Math.min(ctx.data.pagesToday / GOAL, 1);
  return {
    type: 'zstack',
    frame: { width: 110, height: 110 },
    widgetBackground: '#101820',
    children: [
      { type: 'circle', stroke: { color: '#FFFFFF33', width: 3, dash: 'dotted' } },
      { type: 'circle', padding: 8, trimTo: progress, rotation: -90,
        stroke: { color: { gradient: 'angular', stops: ['#F4A259', '#7AE582'], endAngle: 360 * progress },
          width: 10, cap: 'round' } },
      { type: 'path', d: 'M2 12 L9 19 L22 5', viewBox: [0, 0, 24, 24], frame: { width: 30, height: 30 },
        stroke: { color: progress >= 1 ? '#7AE582' : '#FFFFFF44', width: 3, cap: 'round' } },
    ],
  };
}
```

### Images

`image` draws one of the widget's image assets. `asset` is an asset id from the widget's `assets`. Any other id is an error, and a widget with no assets cannot use `image`. Like a shape, an image has no size of its own.

- `mode` is `fill` (the default), which covers the space it is given and crops what spills over, or `fit`, which shows the whole image inside the space and keeps its proportions.
- `crop` picks a part of the image as `[x, y, width, height]`, each a fraction from 0 to 1 measured from the top left. Use it to choose the part of a photo that suits each size.
- `saturation` (0 to 4, default 1; 0 is gray), `brightness` (-1 to 1, default 0), and `contrast` (0 to 4, default 1) adjust the image's colors. The common props `blur`, `opacity`, `blend`, `clip`, and `mask` work on an image as on any node.

```js
function render(ctx) {
  return {
    type: 'zstack', align: 'bottomLeading',
    frame: { maxWidth: 'infinity', maxHeight: 'infinity' },
    widgetBackground: '#000000',
    children: [
      { type: 'image', asset: 'cover', crop: ctx.family === 'small' ? [0.25, 0, 0.5, 1] : null,
        saturation: 0.85, brightness: -0.05 },
      { type: 'rect', fill: { gradient: 'linear', stops: ['#00000000', '#000000CC'], from: 'center', to: 'bottom' } },
      { type: 'vstack', align: 'leading', spacing: 0, padding: 14, children: [
        { type: 'text', value: ctx.data.pagesToday, size: 34, weight: 'bold', design: 'rounded', color: '#FFFFFF',
          lineLimit: 1, minScale: 0.5 },
        { type: 'text', value: 'pages today', size: 12, weight: 'medium', color: '#FFFFFFCC' },
      ] },
    ],
  };
}
```

### Buttons

A `button` makes its children tappable. It has no look of its own, so draw the button in its children.

- `action` is an action id from the widget's `actions`.
- `rowId` says which row the tap is about. An action that changes or deletes a row (`toggle`, `set`, `delete`) needs it. An `insert` takes none. A `form` takes it to edit that row and leaves it out to add a new one.
- `rowId` must be the `id` of a row the look received in `ctx.data` from a query on that action's table. Write `row.id`, never a title or a made-up value.
- `day` says which date an `insertOn` action adds its row on, such as `"2026-11-17"`. Only today and the 365 days before it can be tapped: a button for a later day, such as the rest of this week, draws but does nothing until its day comes. Take it from `ctx.today.date`, `ctx.today.week`, or a `daily` entry's `date`, so a tap on yesterday's bar logs yesterday: `{ type: 'button', action: 'logOn', day: entry.date, children: [...] }`. Every other action takes no `day`.
- A button cannot hold another button.
- Keep a button for every action in both sizes. The small look and the medium look each need a button for every action in at least one state. Make each button at least 30 points across so a finger can hit it.

```js
function bookRow(book) {
  return { type: 'hstack', spacing: 8, children: [
    { type: 'button', action: 'finish', rowId: book.id, children: [
      { type: 'symbol', name: book.done ? 'checkmark.circle.fill' : 'circle', size: 18, color: '#7AE582',
        frame: { width: 30, height: 30 } } ] },
    { type: 'text', value: book.title || 'Untitled', size: 13, color: '#FFFFFF', lineLimit: 1 },
    { type: 'spacer', minLength: 0 },
  ] };
}

function render(ctx) {
  const d = ctx.data;
  return {
    type: 'vstack', align: 'leading', spacing: 0, padding: 12,
    frame: { maxWidth: 'infinity', maxHeight: 'infinity', alignment: 'topLeading' },
    widgetBackground: '#1E2A3A',
    children: [
      { type: 'hstack', children: [
        { type: 'text', value: 'Up next', size: 15, weight: 'bold', color: '#FFFFFF' },
        { type: 'spacer' },
        { type: 'button', action: 'addBook', children: [
          { type: 'symbol', name: 'plus.circle.fill', size: 22, color: '#7AE582', frame: { width: 30, height: 30 } } ] },
      ] },
      d.books.length === 0 && { type: 'text', value: 'No books yet. Tap + to add one.', size: 13, color: '#9FB3C8' },
      d.books.slice(0, 3).map(bookRow),
    ],
  };
}
```

### Common props

Every node takes these props. They apply in this order, whatever order you write them in:

1. `aspectRatio`: width divided by height. The node takes the largest size of that shape that fits.
2. `padding`: a number, or an object with any of `top`, `bottom`, `leading`, `trailing`, `horizontal`, `vertical`.
3. `frame`: an object with any of `width`, `height`, `minWidth`, `maxWidth`, `minHeight`, `maxHeight`, `alignment`. Values are points. `maxWidth` and `maxHeight` also take `"infinity"` to fill the space available. `alignment` places the content inside the frame.
4. `background`: a color, a gradient, or a node drawn behind, sized to this node.
5. `overlay`: a color, a gradient, or a node drawn on top, sized to this node.
6. `cornerRadius`: clips to rounded corners. On a `rect` it rounds the shape instead.
7. `clip`: clips to `rect`, `circle`, `capsule`, or `ellipse`. Use `cornerRadius` or `clip`, not both.
8. `mask`: a color, a gradient, or a node. This node shows only where the mask is opaque, so a gradient from opaque to clear fades it out.
9. `opacity`: 0 to 1.
10. `shadow`: `{ color, radius, x, y }`.
11. `blur`: a radius in points.
12. `scale`: a number, or `{ x, y }`.
13. `rotation`: degrees clockwise.
14. `offset`: `{ x, y }` in points. It moves the drawing, not the layout.
15. `blend`: how this node mixes with what is behind it: `normal`, `multiply`, `screen`, `overlay`, `darken`, `lighten`, `colorDodge`, `colorBurn`, `softLight`, `hardLight`, `difference`, or `exclusion`.

To apply props in another order, wrap the node in a `zstack` and put the later props on the wrapper.

The root node also takes `widgetBackground`: a color, a gradient, or a node that fills the whole widget behind everything, edge to edge. Without it the widget is white. A button inside `widgetBackground` or `mask` cannot be tapped, so it is an error.

```js
function render(ctx) {
  const days = ctx.data.week;
  return {
    type: 'vstack', align: 'leading', spacing: 10, padding: 14,
    frame: { maxWidth: 'infinity', maxHeight: 'infinity', alignment: 'topLeading' },
    widgetBackground: { gradient: 'radial', stops: ['#3A2E5C', '#15102A'], center: 'topLeading', endRadius: 260 },
    children: [
      { type: 'text', value: 'This week', size: 17, fontName: 'Marker Felt', color: '#F1E9FF' },
      { type: 'path', d: 'M1 1 H' + (ctx.width - 29), viewBox: [0, 0, ctx.width - 28, 2], frame: { height: 2 },
        stroke: { color: '#F1E9FF66', width: 2, dash: 'dotted' } },
      { type: 'hstack', spacing: 5, children: days.map(day => ({
        type: 'vstack', spacing: 4, children: [
          { type: 'circle', frame: { width: 14, height: 14 },
            fill: day.count > 0 ? '#FF6B9A' : null,
            stroke: day.count > 0 ? null : { color: '#F1E9FF88', width: 1.5, dash: 'dashed' },
            shadow: day.count > 0 ? { color: '#FF6B9A88', radius: 4 } : null },
          { type: 'text', value: day.weekday.slice(0, 1), size: 9, color: '#F1E9FFAA' },
        ] })) },
      { type: 'text', value: 'read', size: 34, weight: 'black', color: '#FF6B9A', blend: 'screen', opacity: 0.5,
        rotation: -6, frame: { maxWidth: 'infinity', alignment: 'trailing' } },
    ],
  };
}
```

### Values

- Colors are hex strings, `"#RRGGBB"` or `"#RRGGBBAA"` with alpha last. There are no color names.
- A gradient is `{ gradient: 'linear', stops, from, to }`, `{ gradient: 'radial', stops, center, startRadius, endRadius }`, or `{ gradient: 'angular', stops, center, startAngle, endAngle }`. `stops` is a list of 2 to 16 colors spaced evenly, or of `{ color, at }` with `at` from 0 to 1. A point is an alignment name or `[x, y]` with each from 0 to 1. Defaults: `from: 'top'`, `to: 'bottom'`, `center: 'center'`, `startRadius: 0`, `endRadius: 80`, `startAngle: 0`, `endAngle: 360`.
- Alignment names are `topLeading`, `top`, `topTrailing`, `leading`, `center`, `trailing`, `bottomLeading`, `bottom`, `bottomTrailing`.
- A tree has at most 2000 nodes, nested at most 40 deep.

### Limits

There is no scrolling, no text input, and no animation. The only fonts are the system designs and the named fonts above. The only images are the widget's assets.

## Fit the widget

Design for `ctx.width` by `ctx.height`. The app renders every look with no data, with your samples, and with a full state of three-digit counts, full lists, and long text wherever a person or an automation writes text, in both sizes. A render where anything spills past the widget's edge or past a clipping node is rejected, and so is text cut off where you did not set a `lineLimit`.

- Give the root `frame: { maxWidth: 'infinity', maxHeight: 'infinity' }` and an alignment, and put `padding` (12 to 16) inside it.
- Count the height. 158 points minus padding leaves about 130 for content. Text takes about 1.2 times its size per line.
- Show fewer list rows in `small` than in `medium`, and slice lists to what fits, as in `d.books.slice(0, 3)`.
- Give live text `lineLimit` and `minScale`, and use `spacer` with `minLength: 0` where space is tight.
- Use `ctx.family` to change the layout between sizes, not just the font size.

## Draw it in code

When the user describes a look or attaches a reference image, recreate it with nodes. Draw graphics with shapes, paths, and gradients. Set type with `text` and the closest `fontName` or `design`. A look drawn in code stays sharp in both sizes and changes with the data.

- Use an `image` only for what code cannot draw, such as a photograph, a painting, or a texture, and only as a layer under or beside the live data.
- Never use a picture of a design as the background. The words and numbers in it would be frozen and wrong.
- Show the widget's live data, not the words and numbers in a reference picture.
- Keep live data readable on top of an image layer. Put a scrim, a solid panel, or a shadow behind the text.

## A complete look

The whole example widget: a reading ring that fills toward a daily goal, an undo for the last session, a button that logs ten pages, and in the medium size the books up next with a button to finish each.

```js
const GOAL = 30;

function ring(pages) {
  const progress = Math.min(pages / GOAL, 1);
  return { type: 'zstack', frame: { width: 54, height: 54 }, children: [
    { type: 'circle', stroke: { color: '#FFFFFF1F', width: 6 } },
    { type: 'circle', trimTo: progress, rotation: -90,
      stroke: { color: progress >= 1 ? '#7AE582' : '#F4A259', width: 6, cap: 'round' } },
    { type: 'symbol', name: progress >= 1 ? 'checkmark' : 'book.fill', size: 16, weight: 'bold',
      color: progress >= 1 ? '#7AE582' : '#F4A259' },
  ] };
}

function render(ctx) {
  const d = ctx.data;
  const medium = ctx.family === 'medium';

  const summary = {
    type: 'vstack', align: 'leading', spacing: 6,
    frame: { maxHeight: 'infinity', alignment: 'topLeading' },
    children: [
      { type: 'text', value: 'Reading', size: 13, weight: 'semibold', color: '#9FB3C8' },
      { type: 'hstack', spacing: 10, children: [
        ring(d.pagesToday),
        { type: 'vstack', align: 'leading', spacing: 0, children: [
          { type: 'text', value: d.pagesToday, size: 26, weight: 'bold', design: 'rounded', color: '#FFFFFF',
            lineLimit: 1, minScale: 0.5 },
          { type: 'text', value: 'of ' + GOAL + ' pages', size: 11, color: '#9FB3C8', lineLimit: 1 },
        ] },
      ] },
      { type: 'spacer', minLength: 0 },
      { type: 'hstack', spacing: 8, frame: { width: medium ? 120 : null }, children: [
        d.last && { type: 'button', action: 'undo', rowId: d.last.id, children: [
          { type: 'symbol', name: 'arrow.uturn.backward', size: 13, weight: 'bold', color: '#9FB3C8',
            frame: { width: 34, height: 34 }, background: '#FFFFFF14', clip: 'circle' } ] },
        { type: 'spacer', minLength: 0 },
        { type: 'button', action: 'log', children: [
          { type: 'text', value: '+10', size: 14, weight: 'bold', design: 'rounded', color: '#0C1821',
            frame: { width: 52, height: 34 }, background: '#F4A259', clip: 'capsule' } ] },
      ] },
    ],
  };

  const upNext = {
    type: 'vstack', align: 'leading', spacing: 2,
    frame: { maxWidth: 'infinity', maxHeight: 'infinity', alignment: 'topLeading' },
    children: [
      { type: 'hstack', children: [
        { type: 'text', value: 'Up next', size: 13, weight: 'semibold', color: '#9FB3C8' },
        { type: 'spacer' },
        { type: 'button', action: 'addBook', children: [
          { type: 'symbol', name: 'plus', size: 13, weight: 'bold', color: '#9FB3C8', frame: { width: 30, height: 30 } } ] },
      ] },
      d.books.length === 0 && { type: 'text', value: 'Add a book to start.', size: 13, color: '#FFFFFF99' },
      d.books.slice(0, 3).map(book => ({ type: 'hstack', spacing: 6, children: [
        { type: 'button', action: 'finish', rowId: book.id, children: [
          { type: 'symbol', name: 'circle', size: 16, color: '#7AE582', frame: { width: 30, height: 30 } } ] },
        { type: 'text', value: book.title || 'Untitled', size: 13, color: '#FFFFFF', lineLimit: 1 },
      ] })),
    ],
  };

  return {
    type: 'hstack', spacing: 14, padding: 14,
    frame: { maxWidth: 'infinity', maxHeight: 'infinity' },
    widgetBackground: { gradient: 'linear', stops: ['#1B2A41', '#0C1821'], from: 'top', to: 'bottom' },
    children: [
      summary,
      medium && { type: 'rect', fill: '#FFFFFF14', frame: { width: 1 } },
      medium && upNext,
    ],
  };
}
```

## Mistakes and the lines they get

When a look fails, the app sends back one line that names the node and what would be valid. Fix exactly what it names. These are some lines a look can get.

An unknown prop lists the props the node takes:

```js
function render(ctx) {
  return { type: 'vstack', children: [{ type: 'text', value: 'Dune', font: 'Futura' }] };
}
```

```text
text at root.children[0]: unknown prop "font" (text props: value, size, weight, design, italic, color, lineLimit, minScale, align, strikethrough, kerning, fontName; common props: aspectRatio, padding, frame, background, overlay, cornerRadius, clip, mask, opacity, shadow, blur, scale, rotation, offset, blend)
```

A button for an action that deletes a row must say which row:

```js
function render(ctx) {
  return { type: 'button', action: 'undo', children: [{ type: 'symbol', name: 'minus' }] };
}
```

```text
button at root: action "undo" needs "rowId": the id of the row it deletes
```

A `rowId` must be a row's `id`, not another field:

```js
function render(ctx) {
  const book = ctx.data.books[0];
  return { type: 'button', action: 'finish', rowId: book.title, children: [{ type: 'symbol', name: 'circle' }] };
}
```

```text
button at root: "rowId" "Dune" is not the id of a row the look received (books rows come from: books); use a row's id field
```

The clock is not an input:

```js
function render(ctx) {
  const hour = new Date().getHours();
  return { type: 'text', value: hour < 12 ? 'Good morning' : 'Good evening' };
}
```

```text
look is not pure: Date() reads the clock (line 2); draw from ctx only (ctx.today has the date, and nothing may be random)
```

A list can be shorter than you expect, and `latest` can be `null`. Check before you read a field:

```js
function render(ctx) {
  const fourth = ctx.data.books[3];
  return { type: 'text', value: fourth.title };
}
```

```text
look threw TypeError: undefined is not an object (evaluating 'fourth.title') (line 3)
```
