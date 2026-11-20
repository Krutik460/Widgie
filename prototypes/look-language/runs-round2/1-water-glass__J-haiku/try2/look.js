function render(ctx) {
  const d = ctx.data;
  const medium = ctx.family === 'medium';
  const goal = d.goal > 0 ? d.goal : 1;
  const progress = Math.min(Math.max(d.todayCount / goal, 0), 1);
  const done = d.todayCount >= d.goal;

  const glassW = medium ? 66 : 56;
  const glassH = medium ? 110 : 80;
  const innerW = glassW - 8;
  const innerH = glassH - 8;
  const fillH = Math.max(2, innerH * progress);

  const glass = {
    type: 'zstack',
    align: 'bottom',
    frame: { width: glassW, height: glassH },
    children: [
      {
        type: 'rect',
        cornerRadius: 10,
        fill: '#FFFFFF14',
        stroke: { color: '#9FD8FF', width: 2, cap: 'round' },
        frame: { width: glassW, height: glassH },
      },
      {
        type: 'rect',
        cornerRadius: 6,
        fill: { gradient: 'linear', stops: ['#4FC3F7', '#0277BD'], from: 'top', to: 'bottom' },
        frame: { width: innerW, height: fillH },
        offset: { x: 0, y: -4 },
      },
      {
        type: 'circle',
        fill: '#FFFFFF66',
        frame: { width: 5, height: 5 },
        offset: { x: -glassW / 4, y: -glassH / 4 },
      },
      {
        type: 'circle',
        fill: '#FFFFFF55',
        frame: { width: 3, height: 3 },
        offset: { x: glassW / 5, y: -glassH / 3 + fillH / 3 },
      },
    ],
  };

  const countCol = {
    type: 'vstack',
    align: 'leading',
    spacing: 2,
    frame: { width: medium ? 84 : 72 },
    children: [
      {
        type: 'text',
        value: String(d.todayCount),
        size: medium ? 32 : 28,
        weight: 'heavy',
        design: 'rounded',
        color: '#FFFFFF',
        lineLimit: 1,
        minScale: 0.5,
      },
      {
        type: 'text',
        value: '/ ' + d.goal + ' ' + d.unit,
        size: 12,
        weight: 'medium',
        color: '#9FD8FF',
        lineLimit: 1,
        minScale: 0.6,
      },
      done && { type: 'symbol', name: 'checkmark.seal.fill', size: 13, color: '#7AE582' },
    ],
  };

  const maxLast = Math.max(1, ...d.last7);
  const bars = {
    type: 'hstack',
    spacing: 3,
    align: 'bottom',
    children: d.last7.map((n, i) => ({
      type: 'vstack',
      spacing: 2,
      children: [
        {
          type: 'rect',
          cornerRadius: 2,
          fill: i === d.last7.length - 1 ? '#4FC3F7' : '#2B6E96',
          frame: { width: 8, height: 4 + 28 * Math.min(Math.max(n, 0), maxLast) / maxLast },
        },
        { type: 'text', value: String(n), size: 8, color: '#9FD8FF', lineLimit: 1 },
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
        size: medium ? 20 : 18,
        weight: 'bold',
        color: '#03253A',
        frame: { width: 42, height: 42 },
        background: '#4FC3F7',
        clip: 'circle',
      },
    ],
  };

  const undoButton = {
    type: 'button',
    action: 'undoLast',
    children: [
      {
        type: 'symbol',
        name: 'arrow.uturn.backward',
        size: 11,
        weight: 'semibold',
        color: '#9FD8FF',
        frame: { width: 26, height: 26 },
        background: '#FFFFFF1A',
        clip: 'circle',
      },
    ],
  };

  const content = medium
    ? {
        type: 'hstack',
        spacing: 10,
        align: 'center',
        children: [
          glass,
          countCol,
          bars,
          {
            type: 'vstack',
            spacing: 6,
            align: 'center',
            children: [plusButton, undoButton],
          },
        ],
      }
    : {
        type: 'vstack',
        spacing: 6,
        align: 'center',
        children: [
          {
            type: 'hstack',
            spacing: 10,
            align: 'center',
            children: [glass, countCol],
          },
          {
            type: 'hstack',
            spacing: 8,
            align: 'center',
            children: [undoButton, { type: 'spacer' }, plusButton],
          },
        ],
      };

  return {
    type: 'vstack',
    padding: 10,
    frame: { maxWidth: 'infinity', maxHeight: 'infinity', alignment: 'center' },
    widgetBackground: { gradient: 'linear', stops: ['#0B3C5D', '#021B2E'], from: 'top', to: 'bottom' },
    children: [content],
  };
}
