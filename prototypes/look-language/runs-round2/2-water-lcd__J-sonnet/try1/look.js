var INK = '#2B3320';
var GHOST = '#2B332020';

function pad2(n) {
  var s = String(Math.max(0, Math.round(n)));
  return s.length < 2 ? '0' + s : s;
}

function lcdButton(action, symbol) {
  return {
    type: 'button',
    action: action,
    children: [
      {
        type: 'symbol', name: symbol, size: 13, weight: 'heavy', color: '#9DAA86',
        frame: { width: 26, height: 26 }, background: INK, cornerRadius: 4,
      },
    ],
  };
}

function render(ctx) {
  var d = ctx.data;
  var goal = Math.max(1, Math.min(Math.round(d.goal) || 1, 24));
  var today = Math.max(0, d.todayCount || 0);
  var lit = Math.min(Math.round(today), goal);
  var medium = ctx.family === 'medium';

  var digits = pad2(today);
  var ghost = digits.replace(/./g, '8');

  var segments = [];
  for (var i = 0; i < goal; i++) {
    segments.push({
      type: 'rect',
      cornerRadius: 1,
      fill: i < lit ? INK : GHOST,
      frame: { maxWidth: 'infinity', height: 14 },
    });
  }

  var header = {
    type: 'hstack',
    spacing: 4,
    children: [
      { type: 'text', value: 'WATER', size: 11, weight: 'bold', design: 'monospaced', color: INK },
      { type: 'spacer' },
      { type: 'text', value: String(d.unit || '').toUpperCase(), size: 10, design: 'monospaced', color: INK, lineLimit: 1 },
    ],
  };

  var count = {
    type: 'hstack',
    align: 'bottom',
    spacing: 2,
    children: [
      {
        type: 'zstack',
        align: 'trailing',
        children: [
          { type: 'text', value: ghost, size: 38, weight: 'bold', design: 'monospaced', color: GHOST, lineLimit: 1 },
          { type: 'text', value: digits, size: 38, weight: 'bold', design: 'monospaced', color: INK, lineLimit: 1 },
        ],
      },
      { type: 'text', value: '/' + Math.round(d.goal), size: 15, weight: 'bold', design: 'monospaced', color: INK, lineLimit: 1, padding: { bottom: 5 } },
    ],
  };

  var last7 = d.last7 || [];
  var maxV = Math.max(1, d.goal || 1);
  for (var j = 0; j < last7.length; j++) maxV = Math.max(maxV, last7[j]);

  var chart = {
    type: 'hstack',
    align: 'bottom',
    spacing: 4,
    children: last7.map(function (v, k) {
      var isToday = k === last7.length - 1;
      return {
        type: 'rect',
        cornerRadius: 1,
        fill: INK,
        opacity: isToday ? 1 : 0.45,
        frame: { width: 11, height: 3 + 37 * Math.max(0, v) / maxV },
      };
    }),
  };

  var buttons = {
    type: 'vstack',
    spacing: 6,
    children: [lcdButton('addGlass', 'plus'), lcdButton('undoLast', 'minus')],
  };

  var middle = {
    type: 'hstack',
    align: 'center',
    spacing: 8,
    children: [
      count,
      { type: 'spacer' },
      medium && {
        type: 'vstack',
        align: 'trailing',
        spacing: 3,
        children: [
          chart,
          { type: 'text', value: '7 DAYS', size: 9, design: 'monospaced', color: INK },
        ],
      },
      buttons,
    ],
  };

  return {
    type: 'vstack',
    spacing: 8,
    padding: 12,
    frame: { maxWidth: 'infinity', maxHeight: 'infinity', alignment: 'top' },
    widgetBackground: { gradient: 'linear', stops: ['#A9B591', '#8E9C78'], from: 'top', to: 'bottom' },
    children: [
      header,
      middle,
      {
        type: 'hstack',
        spacing: 2,
        padding: 3,
        background: '#2B332012',
        cornerRadius: 3,
        children: segments,
      },
    ],
  };
}
