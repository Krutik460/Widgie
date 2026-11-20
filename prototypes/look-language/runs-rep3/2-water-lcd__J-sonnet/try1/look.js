const INK = '#1F2A1A';
const FAINT = '#1F2A1A22';
const SCREEN = '#A3B18A';

function pad2(n) {
  const s = String(Math.max(0, Math.round(n)));
  return s.length < 2 ? '0' + s : s;
}

function segBar(count, goal, width) {
  const n = Math.max(1, Math.min(Math.round(goal), 24));
  const filled = goal > n
    ? Math.round(Math.min(count / goal, 1) * n)
    : Math.min(Math.max(Math.round(count), 0), n);
  const gap = n > 12 ? 2 : 3;
  const w = Math.max(1, (width - gap * (n - 1)) / n);
  const segs = [];
  for (let i = 0; i < n; i++) {
    segs.push({
      type: 'rect',
      cornerRadius: 1,
      fill: i < filled ? INK : FAINT,
      frame: { width: w, height: 14 },
    });
  }
  return { type: 'hstack', spacing: gap, children: segs };
}

function lcdButton(action, name, big) {
  return {
    type: 'button',
    action: action,
    children: [
      {
        type: 'symbol',
        name: name,
        size: big ? 15 : 12,
        weight: 'bold',
        color: SCREEN,
        frame: { width: big ? 52 : 34, height: 26 },
        background: INK,
        cornerRadius: 4,
      },
    ],
  };
}

function weekPanel(last7, goal, width) {
  const vals = (last7 || []).slice(-7);
  const max = Math.max(goal, 1, ...vals);
  const bw = Math.max(6, (width - 6 * 5) / 7);
  const cols = vals.map((v, i) => ({
    type: 'vstack',
    spacing: 3,
    children: [
      {
        type: 'rect',
        fill: i === vals.length - 1 ? INK : '#1F2A1A88',
        cornerRadius: 1,
        frame: { width: bw, height: 3 + 62 * Math.min(v / max, 1) },
      },
      {
        type: 'rect',
        fill: i === vals.length - 1 ? INK : FAINT,
        frame: { width: bw, height: 2 },
      },
    ],
  }));
  return {
    type: 'vstack',
    align: 'leading',
    spacing: 6,
    frame: { width: width, maxHeight: 'infinity', alignment: 'topLeading' },
    children: [
      { type: 'text', value: 'LAST 7 DAYS', size: 10, weight: 'bold', design: 'monospaced', color: INK },
      {
        type: 'hstack',
        spacing: 5,
        align: 'bottom',
        frame: { height: 68, alignment: 'bottomLeading' },
        children: cols,
      },
      { type: 'text', value: 'GOAL ' + pad2(goal), size: 10, weight: 'bold', design: 'monospaced', color: INK },
    ],
  };
}

function render(ctx) {
  const d = ctx.data;
  const medium = ctx.family === 'medium';
  const innerW = ctx.width - 28;
  const leftW = medium ? 170 : innerW;
  const rightW = innerW - leftW - 10;
  const count = d.todayCount;
  const goal = d.goal;
  const reached = count >= goal;

  const left = {
    type: 'vstack',
    align: 'leading',
    spacing: 6,
    frame: { width: leftW, maxHeight: 'infinity', alignment: 'topLeading' },
    children: [
      {
        type: 'hstack',
        children: [
          { type: 'text', value: String(d.unit).toUpperCase(), size: 11, weight: 'bold', design: 'monospaced', color: INK, lineLimit: 1 },
          { type: 'spacer' },
          { type: 'text', value: reached ? 'GOAL OK' : 'TODAY', size: 10, weight: 'bold', design: 'monospaced', color: INK },
        ],
      },
      {
        type: 'hstack',
        align: 'bottom',
        spacing: 2,
        children: [
          {
            type: 'zstack',
            align: 'trailing',
            children: [
              { type: 'text', value: '88', size: 40, weight: 'bold', design: 'monospaced', color: FAINT },
              { type: 'text', value: pad2(count), size: 40, weight: 'bold', design: 'monospaced', color: INK },
            ],
          },
          { type: 'text', value: '/' + pad2(goal), size: 16, weight: 'bold', design: 'monospaced', color: INK, padding: { bottom: 5 } },
        ],
      },
      segBar(count, goal, leftW),
      {
        type: 'hstack',
        spacing: 6,
        children: [
          lcdButton('undoLast', 'minus', false),
          { type: 'spacer' },
          lcdButton('addGlass', 'plus', true),
        ],
      },
    ],
  };

  const screen = {
    type: 'hstack',
    align: 'top',
    spacing: 10,
    padding: 8,
    frame: { maxWidth: 'infinity', maxHeight: 'infinity', alignment: 'topLeading' },
    background: { gradient: 'linear', stops: ['#A9B78F', '#97A67F'], from: 'top', to: 'bottom' },
    cornerRadius: 10,
    children: [left, medium && weekPanel(d.last7, goal, rightW)],
  };

  return {
    type: 'vstack',
    padding: 6,
    frame: { maxWidth: 'infinity', maxHeight: 'infinity' },
    widgetBackground: '#3A3D35',
    children: [screen],
  };
}
