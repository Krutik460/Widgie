function lerpColor(a, b, t) {
  const pa = [1, 3, 5].map(i => parseInt(a.slice(i, i + 2), 16));
  const pb = [1, 3, 5].map(i => parseInt(b.slice(i, i + 2), 16));
  return '#' + pa.map((v, i) => Math.round(v + (pb[i] - v) * t).toString(16).padStart(2, '0')).join('');
}

function render(ctx) {
  const d = ctx.data;
  const days = d.days || [];
  const doneCount = days.filter(x => x.done).length;
  const progress = Math.min(Math.max(d.streak / 30, 0), 1);
  const ringColor = lerpColor('#E63946', '#7AE582', progress);
  const ringSize = ctx.family === 'medium' ? 110 : 96;
  const flameSize = ctx.family === 'medium' ? 26 : 22;
  const numberSize = ctx.family === 'medium' ? 28 : 24;

  const ring = {
    type: 'zstack',
    children: [
      { type: 'circle', stroke: { color: '#FFFFFF22', width: 9, cap: 'round' }, frame: { width: ringSize, height: ringSize } },
      {
        type: 'circle',
        stroke: { color: ringColor, width: 9, cap: 'round' },
        trimFrom: 0,
        trimTo: Math.max(progress, 0.02),
        rotation: -90,
        frame: { width: ringSize, height: ringSize },
      },
      {
        type: 'vstack',
        spacing: 0,
        children: [
          { type: 'symbol', name: 'flame.fill', size: flameSize, color: ringColor },
          { type: 'text', value: String(d.streak), size: numberSize, weight: 'heavy', design: 'rounded', color: '#FFFFFF' },
        ],
      },
    ],
  };

  const heatCells = days.map(day => ({
    type: 'rect',
    cornerRadius: 2,
    fill: day.done ? '#7AE582' : '#FFFFFF22',
    frame: { width: 7, height: 7 },
  }));

  const grid = {
    type: 'vstack',
    spacing: 3,
    children: [0, 1, 2, 3, 4].map(r => ({
      type: 'hstack',
      spacing: 3,
      children: heatCells.slice(r * 7, r * 7 + 7),
    })),
  };

  const toggleButton = {
    type: 'button',
    action: 'toggleToday',
    children: [
      {
        type: 'symbol',
        name: d.doneToday ? 'checkmark' : 'plus',
        size: 14,
        weight: 'bold',
        color: '#0C1821',
        frame: { width: 30, height: 30 },
        background: d.doneToday ? '#7AE582' : '#FFFFFF',
        clip: 'circle',
      },
    ],
  };

  const titleBlock = {
    type: 'vstack',
    align: 'leading',
    spacing: 2,
    children: [
      { type: 'text', value: d.name, size: 15, weight: 'semibold', color: '#FFFFFF', lineLimit: 1, minScale: 0.6 },
      { type: 'text', value: doneCount + ' of 35 days', size: 11, color: '#9FB3C8', lineLimit: 1 },
      { type: 'spacer' },
      toggleButton,
    ],
  };

  const isMedium = ctx.family === 'medium';

  const content = isMedium
    ? {
        type: 'hstack',
        spacing: 16,
        children: [
          { type: 'vstack', spacing: 0, children: [ring] },
          { type: 'vstack', align: 'leading', spacing: 10, frame: { maxHeight: 'infinity' }, children: [
              titleBlock.children[0],
              titleBlock.children[1],
              { type: 'spacer' },
              grid,
              { type: 'text', value: d.doneToday ? 'Done today' : 'Not done yet', size: 11, color: d.doneToday ? '#7AE582' : '#9FB3C8' },
            ] },
          { type: 'spacer' },
          toggleButton,
        ],
      }
    : {
        type: 'vstack',
        align: 'center',
        spacing: 8,
        children: [
          { type: 'text', value: d.name, size: 14, weight: 'semibold', color: '#FFFFFF', lineLimit: 1, minScale: 0.6 },
          ring,
          grid,
          {
            type: 'hstack',
            spacing: 6,
            children: [
              { type: 'text', value: d.doneToday ? 'Done today' : 'Not done yet', size: 11, color: d.doneToday ? '#7AE582' : '#9FB3C8' },
              { type: 'spacer' },
              toggleButton,
            ],
          },
        ],
      };

  return {
    type: 'vstack',
    align: 'center',
    padding: 14,
    frame: { maxWidth: 'infinity', maxHeight: 'infinity', alignment: 'center' },
    widgetBackground: { gradient: 'linear', stops: ['#1B2A41', '#0C1821'], from: 'top', to: 'bottom' },
    children: [content],
  };
}
