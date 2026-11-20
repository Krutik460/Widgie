var BG = '#9DAA8A';
var INK = '#2B3325';
var DIM = '#2B332522';

function segments(count, goal, segH, spacing) {
  var n = Math.max(1, Math.min(Math.round(goal), 16));
  var items = [];
  for (var i = 0; i < n; i++) {
    items.push({
      type: 'rect',
      cornerRadius: 1,
      fill: i < count ? INK : DIM,
      frame: { maxWidth: 'infinity', height: segH },
    });
  }
  return { type: 'hstack', spacing: spacing, children: items };
}

function histogram(last7, goal, h) {
  var mx = Math.max(goal, 1);
  for (var k = 0; k < last7.length; k++) mx = Math.max(mx, last7[k]);
  var cols = last7.map(function (v, i) {
    var isToday = i === last7.length - 1;
    var bh = 3 + (h - 3) * Math.min(Math.max(v, 0), mx) / mx;
    return {
      type: 'rect',
      cornerRadius: 1,
      fill: isToday ? INK : '#2B332577',
      frame: { maxWidth: 'infinity', height: bh },
    };
  });
  return {
    type: 'hstack',
    align: 'bottom',
    spacing: 4,
    frame: { height: h, alignment: 'bottom' },
    children: cols,
  };
}

function btn(action, name) {
  return {
    type: 'button',
    action: action,
    children: [
      {
        type: 'symbol', name: name, size: 15, weight: 'heavy', color: BG,
        frame: { width: 38, height: 30 },
        background: INK,
        cornerRadius: 5,
      },
    ],
  };
}

function render(ctx) {
  var d = ctx.data;
  var medium = ctx.family === 'medium';
  var count = Math.max(0, Math.round(d.todayCount));
  var reached = count >= d.goal;
  var countStr = String(count);
  if (countStr.length < 2) countStr = '0' + countStr;
  var goalStr = String(Math.round(d.goal));

  var topBar = {
    type: 'hstack',
    spacing: 4,
    children: [
      { type: 'text', value: 'WATER', size: 10, weight: 'bold', design: 'monospaced', color: INK, kerning: 1 },
      { type: 'spacer' },
      reached
        ? { type: 'text', value: 'GOAL!', size: 10, weight: 'bold', design: 'monospaced', color: INK }
        : { type: 'symbol', name: 'drop.fill', size: 10, color: INK },
    ],
  };

  var readout = {
    type: 'hstack',
    align: 'firstBaseline',
    spacing: 4,
    children: [
      { type: 'text', value: countStr, size: medium ? 54 : 46, weight: 'bold', design: 'monospaced', color: INK, lineLimit: 1, minScale: 0.5 },
      { type: 'text', value: '/' + goalStr, size: 16, weight: 'bold', design: 'monospaced', color: INK, lineLimit: 1 },
      { type: 'spacer' },
    ],
  };

  var buttons = {
    type: 'hstack',
    spacing: 6,
    children: [btn('undoLast', 'minus'), btn('addGlass', 'plus')],
  };

  var left = {
    type: 'vstack',
    align: 'leading',
    spacing: 5,
    frame: { maxWidth: 'infinity', maxHeight: 'infinity', alignment: 'topLeading' },
    children: [
      topBar,
      readout,
      { type: 'text', value: String(d.unit).toUpperCase(), size: 10, weight: 'semibold', design: 'monospaced', color: INK, lineLimit: 1 },
      segments(count, d.goal, 12, 2),
      { type: 'spacer' },
      medium ? null : { type: 'hstack', children: [{ type: 'spacer' }, buttons] },
    ],
  };

  var right = {
    type: 'vstack',
    align: 'leading',
    spacing: 6,
    frame: { maxWidth: 'infinity', maxHeight: 'infinity', alignment: 'topLeading' },
    children: [
      { type: 'text', value: 'LAST 7 DAYS', size: 10, weight: 'bold', design: 'monospaced', color: INK, kerning: 1 },
      histogram(d.last7, d.goal, 60),
      { type: 'spacer' },
      { type: 'hstack', children: [{ type: 'spacer' }, buttons] },
    ],
  };

  var screen = {
    type: 'hstack',
    spacing: 14,
    padding: 10,
    frame: { maxWidth: 'infinity', maxHeight: 'infinity' },
    background: BG,
    cornerRadius: 8,
    overlay: { type: 'rect', cornerRadius: 8, stroke: { color: '#2B332555', width: 2 } },
    children: medium ? [left, right] : [left],
  };

  return {
    type: 'zstack',
    padding: 8,
    frame: { maxWidth: 'infinity', maxHeight: 'infinity' },
    widgetBackground: { gradient: 'linear', stops: ['#3A3F3A', '#1E211E'], from: 'top', to: 'bottom' },
    children: [screen],
  };
}
