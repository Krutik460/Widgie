const INK = '#2B3322';
const INK_DIM = '#2B332222';
const INK_MID = '#2B3322AA';
const SCREEN = ['#A9B796', '#93A281'];

function pad2(n) {
  const s = String(Math.max(0, Math.round(n)));
  return s.length < 2 ? '0' + s : s;
}

function render(ctx) {
  const d = ctx.data;
  const count = Math.max(0, d.todayCount || 0);
  const goal = Math.max(1, Math.round(d.goal || 1));
  const segs = Math.min(goal, 24);
  const filled = Math.min(count, goal) / goal * segs;
  const medium = ctx.family === 'medium';

  const segChildren = [];
  for (let i = 0; i < segs; i++) {
    const on = i < Math.round(filled);
    segChildren.push({
      type: 'rect',
      cornerRadius: 1,
      fill: on ? INK : INK_DIM,
      stroke: on ? undefined : { color: INK_MID, width: 1 },
      frame: { maxWidth: 'infinity', height: 14 },
    });
  }

  const header = {
    type: 'hstack',
    children: [
      { type: 'text', value: 'WATER', size: 11, weight: 'bold', design: 'monospaced', color: INK, kerning: 1.5 },
      { type: 'spacer' },
      { type: 'text', value: count >= goal ? 'GOAL!' : String(d.unit || '').toUpperCase(), size: 10, weight: 'bold', design: 'monospaced', color: INK_MID, lineLimit: 1 },
    ],
  };

  const digits = {
    type: 'hstack',
    align: 'bottom',
    spacing: 4,
    children: [
      {
        type: 'zstack',
        align: 'trailing',
        children: [
          { type: 'text', value: '88', size: 46, weight: 'bold', design: 'monospaced', color: INK_DIM },
          { type: 'text', value: pad2(count), size: 46, weight: 'bold', design: 'monospaced', color: INK },
        ],
      },
      { type: 'text', value: '/' + goal, size: 15, weight: 'bold', design: 'monospaced', color: INK_MID, lineLimit: 1, minScale: 0.6, padding: { bottom: 6 } },
      { type: 'spacer' },
    ],
  };

  const bar = { type: 'hstack', spacing: 2, children: segChildren };

  const addBtn = {
    type: 'button',
    action: 'addGlass',
    children: [
      {
        type: 'hstack',
        spacing: 4,
        children: [
          { type: 'symbol', name: 'plus', size: 13, weight: 'bold', color: '#A9B796' },
          { type: 'text', value: 'ADD', size: 12, weight: 'bold', design: 'monospaced', color: '#A9B796' },
        ],
        frame: { maxWidth: 'infinity', height: 30, alignment: 'center' },
        background: INK,
        cornerRadius: 5,
      },
    ],
  };

  const undoBtn = {
    type: 'button',
    action: 'undoLast',
    children: [
      {
        type: 'symbol', name: 'arrow.uturn.backward', size: 13, weight: 'bold', color: INK,
        frame: { width: 38, height: 30 },
        overlay: { type: 'rect', cornerRadius: 5, stroke: { color: INK, width: 2 } },
      },
    ],
  };

  const left = {
    type: 'vstack',
    align: 'leading',
    spacing: 6,
    frame: { maxWidth: 'infinity', maxHeight: 'infinity', alignment: 'topLeading' },
    children: [
      header,
      digits,
      bar,
      { type: 'spacer', minLength: 0 },
      { type: 'hstack', spacing: 6, children: [addBtn, undoBtn] },
    ],
  };

  const last7 = Array.isArray(d.last7) ? d.last7.slice(-7) : [];
  let mx = goal;
  last7.forEach(v => { if (v > mx) mx = v; });

  const bars = last7.map((v, i) => {
    const isToday = i === last7.length - 1;
    const h = 4 + 56 * Math.min(Math.max(v, 0) / mx, 1);
    return {
      type: 'vstack',
      spacing: 3,
      children: [
        { type: 'rect', cornerRadius: 1, fill: isToday ? INK : INK_MID, frame: { height: h, maxWidth: 'infinity' } },
        { type: 'rect', fill: isToday ? INK : INK_DIM, frame: { height: 2, maxWidth: 'infinity' } },
      ],
      frame: { maxWidth: 'infinity' },
    };
  });

  const right = {
    type: 'vstack',
    align: 'leading',
    spacing: 6,
    frame: { maxWidth: 'infinity', maxHeight: 'infinity', alignment: 'topLeading' },
    children: [
      { type: 'text', value: '7 DAY LOG', size: 11, weight: 'bold', design: 'monospaced', color: INK, kerning: 1.5 },
      {
        type: 'hstack',
        align: 'bottom',
        spacing: 5,
        frame: { maxWidth: 'infinity', height: 74, alignment: 'bottom' },
        children: bars,
      },
      { type: 'rect', fill: INK_DIM, frame: { height: 1, maxWidth: 'infinity' } },
      {
        type: 'text',
        value: 'TODAY ' + pad2(count) + ' / ' + pad2(goal),
        size: 11, weight: 'bold', design: 'monospaced', color: INK_MID, lineLimit: 1, minScale: 0.6,
      },
      { type: 'spacer', minLength: 0 },
    ],
  };

  return {
    type: 'hstack',
    spacing: 14,
    padding: 12,
    frame: { maxWidth: 'infinity', maxHeight: 'infinity' },
    widgetBackground: { gradient: 'linear', stops: SCREEN, from: 'top', to: 'bottom' },
    children: medium ? [left, right] : [left],
  };
}
