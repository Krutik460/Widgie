function lerpColor(a, b, t) {
  const pa = [1, 3, 5].map(i => parseInt(a.slice(i, i + 2), 16));
  const pb = [1, 3, 5].map(i => parseInt(b.slice(i, i + 2), 16));
  return '#' + pa.map((v, i) => Math.round(v + (pb[i] - v) * t).toString(16).padStart(2, '0')).join('');
}

function render(ctx) {
  const d = ctx.data;
  const goal = d.goal > 0 ? d.goal : 1;
  const progress = Math.min(Math.max(d.todayCount / goal, 0), 1);
  const isMedium = ctx.family === 'medium';

  const glassW = isMedium ? 74 : 62;
  const glassH = isMedium ? 110 : 96;
  const waterH = Math.max(2, (glassH - 6) * progress);

  const glass = {
    type: 'zstack',
    align: 'bottom',
    frame: { width: glassW, height: glassH },
    children: [
      {
        type: 'rect',
        cornerRadius: 10,
        fill: '#FFFFFF14',
        stroke: { color: '#8FD3FF', width: 2, cap: 'round' },
        frame: { width: glassW, height: glassH },
      },
      {
        type: 'rect',
        cornerRadius: 7,
        fill: lerpColor('#2A7FBF', '#4DD2FF', progress),
        frame: { width: glassW - 6, height: waterH },
        padding: { bottom: 3 },
        overlay: progress > 0 ? {
          type: 'circle',
          fill: '#FFFFFF55',
          frame: { width: 5, height: 5 },
          offset: { x: -10, y: -waterH / 2 + 8 },
        } : null,
      },
    ],
  };

  const bubbles = {
    type: 'zstack',
    frame: { width: glassW, height: glassH },
    children: [
      { type: 'circle', fill: '#FFFFFF66', frame: { width: 4, height: 4 }, offset: { x: -14, y: 18 } },
      { type: 'circle', fill: '#FFFFFF66', frame: { width: 3, height: 3 }, offset: { x: 12, y: 4 } },
    ],
  };

  const countText = {
    type: 'text',
    value: d.todayCount + ' / ' + d.goal,
    size: isMedium ? 22 : 18,
    weight: 'heavy',
    design: 'rounded',
    color: '#E6F7FF',
    lineLimit: 1,
    minScale: 0.6,
  };

  const unitText = {
    type: 'text',
    value: d.unit,
    size: 12,
    weight: 'semibold',
    color: '#8FD3FF',
    lineLimit: 1,
  };

  const max = Math.max(1, ...d.last7, d.goal);
  const bars = {
    type: 'hstack',
    align: 'bottom',
    spacing: 4,
    children: d.last7.map((v, i) => ({
      type: 'rect',
      cornerRadius: 2,
      fill: i === d.last7.length - 1 ? '#4DD2FF' : '#2A7FBF',
      frame: { width: isMedium ? 12 : 9, height: 4 + 30 * Math.min(v, max) / max },
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
        frame: { width: isMedium ? 64 : 56, height: isMedium ? 64 : 56 },
        background: { gradient: 'linear', stops: ['#8FE8FF', '#2A9FE0'], from: 'topLeading', to: 'bottomTrailing' },
        clip: 'circle',
        shadow: { color: '#4DD2FF88', radius: 8, x: 0, y: 2 },
      },
    ],
  };

  const undoButton = {
    type: 'button',
    action: 'undoLast',
    children: [
      { type: 'symbol', name: 'arrow.uturn.backward', size: 14, weight: 'semibold', color: '#8FD3FF' },
    ],
  };

  const left = {
    type: 'vstack',
    align: 'leading',
    spacing: 4,
    children: [countText, unitText],
  };

  const infoColumn = {
    type: 'vstack',
    align: 'leading',
    spacing: 8,
    children: [
      left,
      { type: 'spacer' },
      bars,
      { type: 'text', value: 'Last 7 days', size: 9, color: '#8FD3FF' },
    ],
  };

  const body = isMedium
    ? {
        type: 'hstack',
        spacing: 16,
        children: [
          glass,
          bubbles,
          infoColumn,
          { type: 'spacer' },
          plusButton,
        ],
      }
    : {
        type: 'vstack',
        align: 'center',
        spacing: 6,
        children: [
          {
            type: 'hstack',
            spacing: 10,
            children: [
              glass,
              { type: 'vstack', align: 'leading', spacing: 6, children: [left, { type: 'spacer' }, bars] },
            ],
          },
          { type: 'spacer' },
          {
            type: 'hstack',
            spacing: 14,
            children: [undoButton, plusButton],
          },
        ],
      };

  return {
    type: 'vstack',
    align: 'center',
    padding: 14,
    frame: { maxWidth: 'infinity', maxHeight: 'infinity' },
    widgetBackground: { gradient: 'linear', stops: ['#0B3A5C', '#041A2B'], from: 'top', to: 'bottom' },
    children: [body],
  };
}
