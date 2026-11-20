function render(ctx) {
  const d = ctx.data;
  const goal = Math.max(d.goal || 1, 1);
  const count = Math.max(d.todayCount || 0, 0);
  const progress = Math.min(Math.max(count / goal, 0), 1);
  const isMedium = ctx.family === 'medium';

  const glassW = isMedium ? 84 : 78;
  const glassH = isMedium ? 118 : 106;
  const waterH = Math.max(4, (glassH - 6) * progress);

  const glass = {
    type: 'zstack',
    align: 'bottom',
    frame: { width: glassW, height: glassH },
    children: [
      {
        type: 'rect',
        cornerRadius: 12,
        fill: '#FFFFFF1A',
        stroke: { color: '#BFE9FF', width: 2, cap: 'round' },
        frame: { width: glassW, height: glassH },
      },
      {
        type: 'zstack',
        align: 'bottom',
        frame: { width: glassW - 6, height: glassH - 6 },
        children: [
          {
            type: 'rect',
            cornerRadius: 9,
            fill: { gradient: 'linear', stops: ['#4FC3F7', '#0277BD'], from: 'top', to: 'bottom' },
            frame: { width: glassW - 6, height: waterH },
          },
          {
            type: 'circle',
            fill: '#FFFFFF88',
            frame: { width: 5, height: 5 },
            offset: { x: -14, y: -(waterH / 2) + 6 },
          },
          {
            type: 'circle',
            fill: '#FFFFFF66',
            frame: { width: 3, height: 3 },
            offset: { x: 12, y: -(waterH / 3) },
          },
        ],
      },
    ],
  };

  const countBlock = {
    type: 'vstack',
    align: 'leading',
    spacing: 2,
    children: [
      { type: 'text', value: String(count), size: isMedium ? 40 : 34, weight: 'heavy', design: 'rounded', color: '#FFFFFF', lineLimit: 1, minScale: 0.5 },
      { type: 'text', value: 'of ' + goal + ' ' + (d.unit || 'glasses'), size: 12, weight: 'medium', color: '#9FD8F5', lineLimit: 1, minScale: 0.6 },
    ],
  };

  const maxLast = Math.max(1, ...d.last7);
  const weekBars = {
    type: 'hstack',
    align: 'bottom',
    spacing: 4,
    children: d.last7.map((v, i) => ({
      type: 'vstack',
      spacing: 3,
      children: [
        {
          type: 'rect',
          cornerRadius: 2,
          fill: i === d.last7.length - 1 ? '#7FE3FF' : '#2E7DB5',
          frame: { width: 8, height: 2 + 22 * Math.min(v, maxLast) / maxLast },
        },
      ],
    })),
  };

  const plusButton = {
    type: 'button',
    action: 'addGlass',
    children: [
      {
        type: 'symbol',
        name: 'plus',
        size: isMedium ? 30 : 26,
        weight: 'bold',
        color: '#06243A',
        frame: { width: isMedium ? 58 : 52, height: isMedium ? 58 : 52 },
        background: { gradient: 'linear', stops: ['#8BE9FF', '#29B6F6'], from: 'top', to: 'bottom' },
        clip: 'circle',
        shadow: { color: '#29B6F655', radius: 8, x: 0, y: 3 },
      },
    ],
  };

  const undoButton = {
    type: 'button',
    action: 'undoLast',
    children: [
      { type: 'symbol', name: 'arrow.uturn.backward', size: 13, weight: 'semibold', color: '#9FD8F5', frame: { width: 26, height: 26 }, background: '#FFFFFF1A', clip: 'circle' },
    ],
  };

  const mainRow = {
    type: 'hstack',
    spacing: isMedium ? 16 : 10,
    align: 'center',
    children: isMedium
      ? [glass, countBlock, { type: 'spacer' }, weekBars, plusButton]
      : [glass, { type: 'spacer' }],
  };

  const smallBody = {
    type: 'vstack',
    align: 'center',
    spacing: 6,
    children: [
      glass,
      countBlock,
    ],
  };

  return {
    type: 'zstack',
    align: 'topTrailing',
    frame: { maxWidth: 'infinity', maxHeight: 'infinity' },
    widgetBackground: { gradient: 'linear', stops: ['#0B3C5D', '#042338'], from: 'top', to: 'bottom' },
    children: [
      {
        type: 'hstack',
        spacing: isMedium ? 16 : 0,
        align: 'center',
        padding: 14,
        frame: { maxWidth: 'infinity', maxHeight: 'infinity' },
        children: isMedium
          ? [
              glass,
              {
                type: 'vstack',
                align: 'leading',
                spacing: 10,
                children: [countBlock, weekBars],
              },
              { type: 'spacer' },
              plusButton,
            ]
          : [
              {
                type: 'vstack',
                align: 'center',
                spacing: 6,
                children: [glass, countBlock],
              },
              { type: 'spacer' },
              {
                type: 'vstack',
                align: 'center',
                spacing: 8,
                children: [plusButton],
              },
            ],
      },
      { type: 'zstack', children: [undoButton], padding: 8 },
    ],
  };
}
