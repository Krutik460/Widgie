var ON = '#39FF14';
var ON_DIM = '#1FA80F';
var OFF = '#0E2A12';
var BG = '#000000';

function cell(days, i, size, isToday) {
  var d = days[i];
  var done = !!(d && d.done);
  var prevDone = i > 0 && days[i - 1] && days[i - 1].done;
  var node = {
    type: 'rect',
    cornerRadius: Math.max(2, size * 0.22),
    fill: done ? (prevDone ? ON : ON_DIM) : OFF,
    frame: { width: size, height: size },
  };
  if (done) node.shadow = { color: '#39FF1488', radius: 3, x: 0, y: 0 };
  if (isToday) node.stroke = { color: '#FFFFFF', width: 1.5 };
  return node;
}

function grid(days, size, gap) {
  var cols = [];
  for (var w = 0; w < 5; w++) {
    var cells = [];
    for (var r = 0; r < 7; r++) {
      var i = w * 7 + r;
      cells.push(cell(days, i, size, i === days.length - 1));
    }
    cols.push({ type: 'vstack', spacing: gap, children: cells });
  }
  return { type: 'hstack', spacing: gap, children: cols };
}

function toggle(done, size) {
  return {
    type: 'button',
    action: 'toggleToday',
    children: [
      {
        type: 'symbol',
        name: done ? 'checkmark' : 'plus',
        size: size * 0.5,
        weight: 'bold',
        color: done ? '#000000' : ON,
        frame: { width: size, height: size },
        background: done ? ON : '#0E2A12',
        clip: 'circle',
        shadow: done ? { color: '#39FF1499', radius: 5, x: 0, y: 0 } : undefined,
      },
    ],
  };
}

function render(ctx) {
  var d = ctx.data;
  var days = d.days || [];
  var streak = d.streak || 0;
  var streakLabel = streak + (streak === 1 ? ' day streak' : ' day streak');

  if (ctx.family === 'medium') {
    return {
      type: 'hstack',
      spacing: 18,
      padding: 14,
      align: 'center',
      frame: { maxWidth: 'infinity', maxHeight: 'infinity', alignment: 'center' },
      widgetBackground: BG,
      children: [
        {
          type: 'vstack',
          align: 'leading',
          spacing: 2,
          frame: { maxWidth: 'infinity', maxHeight: 'infinity', alignment: 'topLeading' },
          children: [
            { type: 'text', value: d.name, size: 17, weight: 'bold', color: '#FFFFFF', lineLimit: 1, minScale: 0.7 },
            { type: 'text', value: 'LAST 5 WEEKS', size: 9, weight: 'semibold', color: '#2E7D32', kerning: 1 },
            { type: 'spacer' },
            { type: 'text', value: String(streak), size: 44, weight: 'heavy', design: 'rounded', color: ON, shadow: { color: '#39FF1488', radius: 6, x: 0, y: 0 } },
            { type: 'text', value: streak === 1 ? 'day streak' : 'days streak', size: 12, weight: 'medium', color: '#7CCB6F' },
            { type: 'spacer' },
            toggle(!!d.doneToday, 32),
          ],
        },
        grid(days, 15, 4),
      ],
    };
  }

  return {
    type: 'vstack',
    align: 'leading',
    spacing: 6,
    padding: 11,
    frame: { maxWidth: 'infinity', maxHeight: 'infinity', alignment: 'topLeading' },
    widgetBackground: BG,
    children: [
      {
        type: 'hstack',
        align: 'center',
        spacing: 6,
        children: [
          {
            type: 'vstack',
            align: 'leading',
            spacing: 1,
            children: [
              { type: 'text', value: d.name, size: 13, weight: 'bold', color: '#FFFFFF', lineLimit: 1, minScale: 0.7 },
              { type: 'text', value: streakLabel, size: 10, weight: 'semibold', color: ON, lineLimit: 1, minScale: 0.7 },
            ],
          },
          { type: 'spacer' },
          toggle(!!d.doneToday, 26),
        ],
      },
      {
        type: 'hstack',
        frame: { maxWidth: 'infinity', alignment: 'center' },
        children: [grid(days, 14, 3)],
      },
    ],
  };
}
