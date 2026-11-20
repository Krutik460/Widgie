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
