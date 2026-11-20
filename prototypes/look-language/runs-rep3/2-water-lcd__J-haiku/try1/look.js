function render(ctx) {
  const d = ctx.data;
  const goal = Math.max(d.goal, 1);
  const count = Math.max(d.todayCount, 0);
  const SCREEN = '#9BAE9A';
  const INK = '#1F2B22';
  const DIM = '#5E6E60';
  const MAX_SEG = 12;
  const segs = Math.min(goal, MAX_SEG);
  const perSeg = goal / segs;
  const filled = Math.min(Math.floor(count / perSeg + 1e-9), segs);

  const segBar = {
    type: 'hstack',
    spacing: 2,
    children: Array.from({ length: segs }, (_, i) => ({
      type: 'rect',
      cornerRadius: 1,
      fill: i < filled ? INK : '#7F927F',
      frame: { height: 10, maxWidth: 'infinity' },
    })),
  };

  const last = d.last7.slice(-7);
  const peak = Math.max(goal, ...last, 1);
  const bars = last.map((v, i) => ({
    type: 'vstack',
    align: 'center',
    spacing: 2,
    children: [
      { type: 'rect', fill: INK, frame: { width: 6, height: Math.max(2, 22 * Math.min(v, peak) / peak) } },
      { type: 'text', value: String(i + 1), size: 8, design: 'monospaced', color: DIM },
    ],
  }));

  const countText = {
    type: 'text',
    value: count + '/' + d.goal,
    size: ctx.family === 'medium' ? 40 : 34,
    weight: 'bold',
    design: 'monospaced',
    color: INK,
    lineLimit: 1,
    minScale: 0.5,
  };

  const unitText = {
    type: 'text',
    value: d.unit.toUpperCase(),
    size: 11,
    weight: 'semibold',
    design: 'monospaced',
    color: INK,
    lineLimit: 1,
    minScale: 0.6,
  };

  const undoBtn = {
    type: 'button',
    action: 'undoLast',
    children: [
      {
        type: 'text', value: '-', size: 18, weight: 'bold', design: 'monospaced', color: INK,
        frame: { width: 30, height: 26 }, background: '#7F927F', cornerRadius: 4,
      },
    ],
  };

  const addBtn = {
    type: 'button',
    action: 'addGlass',
    children: [
      {
        type: 'text', value: '+', size: 18, weight: 'bold', design: 'monospaced', color: SCREEN,
        frame: { width: 30, height: 26 }, background: INK, cornerRadius: 4,
      },
    ],
  };

  const screen = {
    type: 'vstack',
    align: 'leading',
    spacing: 6,
    padding: 10,
    frame: { maxWidth: 'infinity', maxHeight: 'infinity' },
    background: SCREEN,
    cornerRadius: 10,
    overlay: {
      type: 'rect',
      stroke: { color: '#00000033', width: 2, cap: 'butt' },
      cornerRadius: 10,
    },
    children: ctx.family === 'medium'
      ? [
          {
            type: 'hstack',
            spacing: 12,
            align: 'center',
            children: [
              {
                type: 'vstack',
                align: 'leading',
                spacing: 4,
                children: [
                  { type: 'text', value: 'WATER', size: 10, weight: 'bold', design: 'monospaced', color: DIM },
                  countText,
                  unitText,
                ],
              },
              { type: 'spacer' },
              {
                type: 'vstack',
                align: 'leading',
                spacing: 4,
                children: [
                  { type: 'text', value: 'LAST 7 DAYS', size: 8, design: 'monospaced', color: DIM },
                  { type: 'hstack', spacing: 4, align: 'bottom', children: bars },
                ],
              },
            ],
          },
          segBar,
          {
            type: 'hstack',
            spacing: 8,
            children: [
              { type: 'text', value: 'GOAL ' + d.goal, size: 10, design: 'monospaced', color: DIM },
              { type: 'spacer' },
              undoBtn,
              addBtn,
            ],
          },
        ]
      : [
          { type: 'text', value: 'WATER', size: 10, weight: 'bold', design: 'monospaced', color: DIM },
          countText,
          unitText,
          segBar,
          { type: 'spacer' },
          {
            type: 'hstack',
            spacing: 6,
            align: 'bottom',
            children: [
              { type: 'hstack', spacing: 4, align: 'bottom', children: bars },
              { type: 'spacer' },
              undoBtn,
              addBtn,
            ],
          },
        ],
  };

  return {
    type: 'zstack',
    widgetBackground: '#4F5F52',
    children: [screen],
  };
}
