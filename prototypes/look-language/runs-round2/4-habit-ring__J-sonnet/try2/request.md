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
| `text` | a run of text | `value`, `size` (default 15), `weight`, `design`, `italic`, `color`, `lineLimit`, `minScale`, `align`, `strikethrough`, `kerning`, `fontName` |
| `symbol` | an SF Symbol icon | `name`, `size` (default 17), `weight`, `color` |
| `rect` | rectangle, fills the space it is given | `cornerRadius`, `fill`, `stroke`, `trimFrom`, `trimTo` |
| `circle` | circle, fits the space it is given | `fill`, `stroke`, `trimFrom`, `trimTo` |
| `capsule` | pill shape, fills the space it is given | `fill`, `stroke`, `trimFrom`, `trimTo` |
| `ellipse` | ellipse, fills the space it is given | `fill`, `stroke`, `trimFrom`, `trimTo` |
| `path` | custom shape | `d` (SVG path data), `viewBox` (`[minX, minY, width, height]`), `fill`, `stroke`, `trimFrom`, `trimTo` |
| `image` | one of the widget's image assets | `asset` (an asset id), `mode` (fill or fit), `crop` (`[x, y, width, height]`) |
| `button` | makes its children tappable; looks exactly like its children, layered as in a zstack | `action` (an action id), `rowId` (optional, the id of the data row the tap is about), `children` |

Text details: `weight` is one of ultraLight, thin, light, regular, medium, semibold, bold, heavy, black. `design` is one of default, serif, rounded, monospaced. `align` is leading, center, or trailing and affects multi-line text. `lineLimit` is the maximum number of lines. `minScale` (0 to 1) lets text shrink to fit. `italic` and `strikethrough` are true or false. Text and symbols are black unless you set `color`.

Named fonts: `fontName` sets a font family from the list below and replaces `design`. `weight` and `italic` then pick the nearest face the family has, and some families have a single face. A named font can be wider or taller than the system font at the same `size`, so leave room. Any other name is an error.

| `fontName` | style |
|---|---|
| `Bradley Hand` | handwriting, a quick pen (one face) |
| `Noteworthy` | handwriting, neat notes (light and bold) |
| `Marker Felt` | handwriting, felt marker (thin and wide) |
| `Chalkduster` | display, chalk on a blackboard (one face) |
| `Snell Roundhand` | script, formal calligraphy |
| `American Typewriter` | typewriter |
| `Rockwell` | slab serif |
| `DIN Condensed` | condensed bold signage, best in capitals (one face) |
| `Avenir Next Condensed` | condensed, clean, every weight |
| `Futura` | display, geometric poster type |
| `Copperplate` | display, engraved small capitals |
| `Didot` | display, high contrast fashion serif |

Image details: `image` draws an image asset. `asset` is an asset id. Your task lists the ids that exist. Any other id is an error, and when the task lists none, do not use `image`. `mode` is `fill` (the default: cover the space the node is given and crop the excess, never spilling outside it) or `fit` (show the whole image inside the space, keeping its proportions). `crop` is optional and picks the part of the image to draw, as `[x, y, width, height]` in fractions of the image from 0 to 1, measured from the top left. Like a shape, a `fill` image has no size of its own, so give it a `frame` or let a parent size it. `cornerRadius`, `clip`, `mask`, `opacity`, and `blur` work on it as on any node.

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

There is no scrolling, no text input, and no animation. The only fonts are the system designs and the named fonts above. The only images are the assets your task lists. Whatever does not fit is cut off, so size things for 158 points of height.

### When the user gives a reference image

Sometimes the user attaches a picture and asks for the widget to look like it. You are shown the picture, and the same picture is available as the image asset `reference`.

- Recreate what you see in code: the layout, colors, shapes, borders, patterns, and type. Draw graphics with shapes, paths, and gradients. Set type with `text` and pick the closest `fontName` or `design`. A look drawn in code stays sharp in both sizes and changes with the data.
- Use `{ "type": "image", "asset": "reference" }` as a layer only for what code cannot draw, such as a photograph, a painting, or a texture. Never paste a picture of a design in as the background, because the words and numbers inside it would be frozen and wrong. Use `crop` to pick the part of a photo that suits each size.
- Show the widget's live data, not the words and numbers in the picture. Keep the data legible on top of an image layer: put a scrim, a solid panel, or a shadow behind text.
- Keep a button for every action your task lists.

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

```js
function lerpColor(a, b, t) {
  const pa = [1, 3, 5].map(i => parseInt(a.slice(i, i + 2), 16));
  const pb = [1, 3, 5].map(i => parseInt(b.slice(i, i + 2), 16));
  return '#' + pa.map((v, i) => Math.round(v + (pb[i] - v) * t).toString(16).padStart(2, '0')).join('');
}

function render(ctx) {
  const d = ctx.data;
  const progress = Math.min(Math.max(d.pagesRead / d.pagesGoal, 0), 1);

  const header = {
    type: 'hstack',
    spacing: 6,
    children: [
      { type: 'text', value: d.title, size: 17, weight: 'bold', design: 'serif', color: '#FFFFFF', lineLimit: 1 },
      { type: 'spacer' },
      d.pagesRead >= d.pagesGoal
        ? { type: 'symbol', name: 'checkmark.seal.fill', size: 16, color: '#7AE582' }
        : { type: 'text', value: Math.round(100 * progress) + '%', size: 13, weight: 'semibold', color: '#9FB3C8' },
    ],
  };

  const bar = {
    type: 'zstack',
    align: 'leading',
    children: [
      { type: 'capsule', fill: '#FFFFFF22', frame: { height: 8 } },
      {
        type: 'capsule',
        fill: lerpColor('#F4A259', '#7AE582', progress),
        frame: { width: (ctx.width - 28) * progress, height: 8 },
      },
    ],
  };

  const columns = d.sessions.map((s, i) => ({
    type: 'vstack',
    spacing: 3,
    children: [
      {
        type: 'rect',
        cornerRadius: 3,
        fill: i === d.sessions.length - 1 ? '#7AE582' : '#5C7C99',
        frame: { width: 10, height: 4 + 36 * Math.min(s.pages, 40) / 40 },
      },
      { type: 'text', value: s.day, size: 9, color: '#9FB3C8' },
    ],
  }));

  const addButton = {
    type: 'button',
    action: 'logPages',
    children: [
      {
        type: 'symbol', name: 'plus', size: 16, weight: 'bold', color: '#0C1821',
        frame: { width: 34, height: 34 }, background: '#7AE582', clip: 'circle',
      },
    ],
  };

  return {
    type: 'vstack',
    align: 'leading',
    spacing: 8,
    padding: 14,
    frame: { maxWidth: 'infinity', maxHeight: 'infinity', alignment: 'topLeading' },
    widgetBackground: { gradient: 'linear', stops: ['#1B2A41', '#0C1821'], from: 'top', to: 'bottom' },
    children: [
      header,
      bar,
      ctx.family === 'medium' && { type: 'text', value: d.pagesRead + ' of ' + d.pagesGoal + ' pages', size: 12, color: '#9FB3C8' },
      {
        type: 'hstack',
        align: 'bottom',
        spacing: 6,
        frame: { maxHeight: 'infinity', alignment: 'bottom' },
        children: [columns, { type: 'spacer' }, addButton],
      },
    ],
  };
}
```

---

# Your task

Write the look for this widget.

## Data

The widget's data has these fields:

```
name: string, the habit
streak: number, the current streak in days
doneToday: boolean
days: list of exactly 35 { date: "YYYY-MM-DD", done: boolean }, oldest first, today last
```

One sample of the data. The values change over time, and the look must work for any values:

```json
{
  "name": "Meditate",
  "streak": 2,
  "doneToday": true,
  "days": [
    {
      "date": "2026-10-15",
      "done": false
    },
    {
      "date": "2026-10-16",
      "done": true
    },
    {
      "date": "2026-10-17",
      "done": true
    },
    {
      "date": "2026-10-18",
      "done": false
    },
    {
      "date": "2026-10-19",
      "done": false
    },
    {
      "date": "2026-10-20",
      "done": true
    },
    {
      "date": "2026-10-21",
      "done": false
    },
    {
      "date": "2026-10-22",
      "done": false
    },
    {
      "date": "2026-10-23",
      "done": true
    },
    {
      "date": "2026-10-24",
      "done": true
    },
    {
      "date": "2026-10-25",
      "done": true
    },
    {
      "date": "2026-10-26",
      "done": false
    },
    {
      "date": "2026-10-27",
      "done": false
    },
    {
      "date": "2026-10-28",
      "done": false
    },
    {
      "date": "2026-10-29",
      "done": true
    },
    {
      "date": "2026-10-30",
      "done": false
    },
    {
      "date": "2026-10-31",
      "done": false
    },
    {
      "date": "2026-11-01",
      "done": true
    },
    {
      "date": "2026-11-02",
      "done": true
    },
    {
      "date": "2026-11-03",
      "done": false
    },
    {
      "date": "2026-11-04",
      "done": false
    },
    {
      "date": "2026-11-05",
      "done": false
    },
    {
      "date": "2026-11-06",
      "done": true
    },
    {
      "date": "2026-11-07",
      "done": false
    },
    {
      "date": "2026-11-08",
      "done": false
    },
    {
      "date": "2026-11-09",
      "done": true
    },
    {
      "date": "2026-11-10",
      "done": true
    },
    {
      "date": "2026-11-11",
      "done": false
    },
    {
      "date": "2026-11-12",
      "done": false
    },
    {
      "date": "2026-11-13",
      "done": true
    },
    {
      "date": "2026-11-14",
      "done": true
    },
    {
      "date": "2026-11-15",
      "done": false
    },
    {
      "date": "2026-11-16",
      "done": false
    },
    {
      "date": "2026-11-17",
      "done": true
    },
    {
      "date": "2026-11-18",
      "done": true
    }
  ]
}
```

## Actions

- `toggleToday`: marks today done or not done

Use these ids as the `action` of `button` nodes. No other action ids exist.

## Images

This widget has no image assets. Do not use `image`.

## Sizes

The same look is drawn in both families: small (158 x 158 points) and medium (338 x 158 points). It must look right in both.

## The look the user asked for

"a ring that goes from red to green as my streak grows, with a flame in the middle and the streak number"

Reply with the look only, as one fenced ```js code block. No explanation before or after.

---

# Your previous attempt

```js
function lerpColor(a, b, t) {
  const pa = [1, 3, 5].map(i => parseInt(a.slice(i, i + 2), 16));
  const pb = [1, 3, 5].map(i => parseInt(b.slice(i, i + 2), 16));
  return '#' + pa.map((v, i) => Math.round(v + (pb[i] - v) * t).toString(16).padStart(2, '0')).join('');
}

function streakColor(t) {
  t = Math.min(Math.max(t, 0), 1);
  if (t < 0.5) return lerpColor('#FF453A', '#FFD60A', t * 2);
  return lerpColor('#FFD60A', '#30D158', (t - 0.5) * 2);
}

function render(ctx) {
  const d = ctx.data;
  const medium = ctx.family === 'medium';
  const goal = 30;
  const streak = Math.max(0, d.streak || 0);
  const progress = Math.min(streak / goal, 1);
  const color = streakColor(progress);
  const size = medium ? 124 : 108;
  const stroke = 10;

  const ringChildren = [
    { type: 'circle', stroke: { color: '#FFFFFF1F', width: stroke }, frame: { width: size, height: size } },
    progress > 0 && {
      type: 'circle',
      stroke: { color: color, width: stroke, cap: 'round' },
      trimFrom: 0,
      trimTo: progress,
      rotation: -90,
      frame: { width: size, height: size },
    },
    {
      type: 'vstack',
      spacing: 0,
      align: 'center',
      children: [
        { type: 'symbol', name: 'flame.fill', size: medium ? 28 : 24, color: d.doneToday ? color : '#8A8F98' },
        { type: 'text', value: String(streak), size: medium ? 34 : 30, weight: 'bold', design: 'rounded', color: '#FFFFFF', lineLimit: 1, minScale: 0.5 },
        { type: 'text', value: streak === 1 ? 'day streak' : 'day streak', size: 10, weight: 'medium', color: '#A7ADB8', lineLimit: 1 },
      ],
      frame: { width: size - stroke * 2 - 6 },
    },
  ];

  const ring = {
    type: 'button',
    action: 'toggleToday',
    children: [{ type: 'zstack', align: 'center', children: ringChildren, frame: { width: size, height: size } }],
  };

  const nameText = {
    type: 'text',
    value: d.name,
    size: medium ? 17 : 13,
    weight: 'semibold',
    color: '#FFFFFF',
    lineLimit: 1,
    minScale: 0.7,
  };

  let content;
  if (!medium) {
    content = {
      type: 'vstack',
      spacing: 6,
      align: 'center',
      padding: 10,
      frame: { maxWidth: 'infinity', maxHeight: 'infinity', alignment: 'center' },
      children: [nameText, ring],
    };
  } else {
    const days = d.days || [];
    const rows = [];
    for (let i = 0; i < days.length; i += 7) rows.push(days.slice(i, i + 7));
    const grid = {
      type: 'vstack',
      spacing: 4,
      align: 'leading',
      children: rows.map((row, r) => ({
        type: 'hstack',
        spacing: 4,
        children: row.map((day, c) => {
          const isToday = r * 7 + c === days.length - 1;
          return {
            type: 'rect',
            cornerRadius: 4,
            fill: day.done ? color : '#FFFFFF1A',
            stroke: isToday ? { color: '#FFFFFF', width: 1.5 } : undefined,
            frame: { width: 17, height: 17 },
          };
        }),
      })),
    };
    const status = {
      type: 'hstack',
      spacing: 5,
      children: [
        { type: 'symbol', name: d.doneToday ? 'checkmark.circle.fill' : 'circle', size: 13, color: d.doneToday ? '#30D158' : '#A7ADB8' },
        { type: 'text', value: d.doneToday ? 'Done today' : 'Tap ring to check in', size: 12, weight: 'medium', color: '#A7ADB8', lineLimit: 1, minScale: 0.7 },
      ],
    };
    content = {
      type: 'hstack',
      spacing: 18,
      align: 'center',
      padding: { horizontal: 16, vertical: 12 },
      frame: { maxWidth: 'infinity', maxHeight: 'infinity', alignment: 'center' },
      children: [
        ring,
        {
          type: 'vstack',
          spacing: 8,
          align: 'leading',
          children: [nameText, grid, status],
        },
      ],
    };
  }

  content.widgetBackground = { gradient: 'linear', stops: ['#1F2230', '#0E1018'], from: 'top', to: 'bottom' };
  return content;
}

```

# It draws without errors, but it does not fit the widget

The app drew it in both sizes with two data samples and measured it. Whatever falls outside the widget is cut off. The small widget is 158 x 158 points and the medium widget is 338 x 158 points.

- small (158 x 158 points), the sample data above: fits.
- small (158 x 158 points), the second data sample below: fits.
- medium (338 x 158 points), the sample data above: does not fit. The layout needs 338 x 171 points, which is 13 pt too tall. It is centered, so the excess is cut off on both sides.
- medium (338 x 158 points), the second data sample below: does not fit. The layout needs 338 x 171 points, which is 13 pt too tall. It is centered, so the excess is cut off on both sides.

The second data sample:

```json
{"name":"Meditate","streak":21,"doneToday":true,"days":[{"date":"2026-10-15","done":true},{"date":"2026-10-16","done":false},{"date":"2026-10-17","done":true},{"date":"2026-10-18","done":true},{"date":"2026-10-19","done":false},{"date":"2026-10-20","done":false},{"date":"2026-10-21","done":true},{"date":"2026-10-22","done":true},{"date":"2026-10-23","done":false},{"date":"2026-10-24","done":true},{"date":"2026-10-25","done":false},{"date":"2026-10-26","done":true},{"date":"2026-10-27","done":true},{"date":"2026-10-28","done":false},{"date":"2026-10-29","done":true},{"date":"2026-10-30","done":true},{"date":"2026-10-31","done":true},{"date":"2026-11-01","done":true},{"date":"2026-11-02","done":true},{"date":"2026-11-03","done":true},{"date":"2026-11-04","done":true},{"date":"2026-11-05","done":true},{"date":"2026-11-06","done":true},{"date":"2026-11-07","done":true},{"date":"2026-11-08","done":true},{"date":"2026-11-09","done":true},{"date":"2026-11-10","done":true},{"date":"2026-11-11","done":true},{"date":"2026-11-12","done":true},{"date":"2026-11-13","done":true},{"date":"2026-11-14","done":true},{"date":"2026-11-15","done":true},{"date":"2026-11-16","done":true},{"date":"2026-11-17","done":true},{"date":"2026-11-18","done":true}]}
```

Change the look so that everything fits inside the widget in both sizes, with nothing cut off and no text cut short. Keep the design the user asked for. Make things smaller or tighter, or show less in the small size. Clipping or hiding the overflow is not a fix.

Reply with the complete corrected look only, as one fenced ```js code block. No explanation before or after.