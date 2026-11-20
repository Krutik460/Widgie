function lerpColor(a, b, t) {
  const pa = [1, 3, 5].map(i => parseInt(a.slice(i, i + 2), 16));
  const pb = [1, 3, 5].map(i => parseInt(b.slice(i, i + 2), 16));
  return '#' + pa.map((v, i) => Math.round(v + (pb[i] - v) * t).toString(16).padStart(2, '0')).join('');
}

function render(ctx) {
  const d = ctx.data;
  const goal = d.goal > 0 ? d.goal : 1;
  const progress = Math.min(Math.max(d.todayCount / goal, 0), 1);
  const done = d.todayCount >= d.goal;

  const glassW = ctx.family === 'medium' ? 84 : 66;
  const glassH = ctx.family === 'medium' ? 112 : 104;
  const fillH = Math.max(2, (glassH - 4) * progress);

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
        fill: { gradient: 'linear', stops: ['#4FC3F7', '#0277BD'], from: 'top', to: 'bottom' },
        frame: { width: glassW - 6, height: fillH },
        clip: 'rect',
        padding: { bottom: 2 },
      },
      {
        type: 'circle',
        fill: '#FFFFFF66',
        frame: { width: 6, height: 6 },
        offset: { x: -glassW / 4, y: -glassH / 4 },
      },
      {
        type: 'circle',
        fill: '#FFFFFF55',
        frame: { width: 4, height: 4 },
        offset: { x: glassW / 5, y: -glassH / 3 + fillH / 3 },
      },
    ],
  };

  const countText = {
    type: 'vstack',
    align: 'leading',
    spacing: 2,
    children: [
      { type: 'text', value: String(d.todayCount), size: ctx.family === 'medium' ? 34 : 30, weight: 'heavy', design: 'rounded', color: '#FFFFFF', lineLimit: 1, minScale: 0.5 },
      { type: 'text', value: '/ ' + d.goal + ' ' + d.unit, size: 12, weight: 'medium', color: '#9FD8FF', lineLimit: 1, minScale: 0.6 },
      done && { type: 'symbol', name: 'checkmark.seal.fill', size: 14, color: '#7AE582' },
    ],
  };

  const maxLast = Math.max(1, ...d.last7);
  const bars = d.last7.map((n, i) => ({
    type: 'vstack',
    spacing: 3,
    children: [
      {
        type: 'rect',
        cornerRadius: 3,
        fill: i === d.last7.length - 1 ? '#4FC3F7' : '#2B6E96',
        frame: { width: 10, height: 4 + 30 * Math.min(n, maxLast) / maxLast },
      },
      { type: 'text', value: String(n), size: 8, color: '#9FD8FF' },
    ],
  }));

  const plusButton = {
    type: 'button',
    action: 'addGlass',
    children: [
      {
        type: 'symbol', name: 'plus', size: 22, weight: 'bold', color: '#03253A',
        frame: { width: 46, height: 46 }, background: '#4FC3F7', clip: 'circle',
      },
    ],
  };

  const undoButton = {
    type: 'button',
    action: 'undoLast',
    children: [
      {
        type: 'symbol', name: 'arrow.uturn.backward', size: 12, weight: 'semibold', color: '#9FD8FF',
        frame: { width: 28, height: 28 }, background: '#FFFFFF1A', clip: 'circle',
      },
    ],
  };

  const medium = ctx.family === 'medium';

  const content = medium
    ? {
        type: 'hstack',
        spacing: 14,
        align: 'center',
        children: [
          glass,
          countText,
          { type: 'spacer' },
          {
            type: 'hstack',
            spacing: 8,
            align: 'bottom',
            children: [bars, { type: 'spacer', minLength: 4 }],
          },
          {
            type: 'vstack',
            spacing: 8,
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
            spacing: 8,
            align: 'center',
            children: [glass, { type: 'vstack', spacing: 2, align: 'leading', children: [countText] }],
          },
          {
            type: 'hstack',
            spacing: 8,
            children: [undoButton, { type: 'spacer' }, plusButton],
          },
        ],
      };

  return {
    type: 'vstack',
    padding: 12,
    frame: { maxWidth: 'infinity', maxHeight: 'infinity', alignment: 'center' },
    widgetBackground: { gradient: 'linear', stops: ['#0B3C5D', '#021B2E'], from: 'top', to: 'bottom' },
    children: [content],
  };
}
