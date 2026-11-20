function lerpColor(a, b, t) {
  const pa = [1, 3, 5].map(i => parseInt(a.slice(i, i + 2), 16));
  const pb = [1, 3, 5].map(i => parseInt(b.slice(i, i + 2), 16));
  return '#' + pa.map((v, i) => Math.round(v + (pb[i] - v) * t).toString(16).padStart(2, '0')).join('');
}

function render(ctx) {
  const d = ctx.data;
  const t = Math.min(Math.max(d.streak / 30, 0), 1);
  const color = lerpColor('#E53935', '#43A047', t);

  const ring = {
    type: 'zstack',
    frame: { width: 108, height: 108 },
    children: [
      { type: 'circle', stroke: { color: '#FFFFFF22', width: 10, cap: 'round' } },
      t > 0 && {
        type: 'circle',
        stroke: { color: color, width: 10, cap: 'round' },
        trimFrom: 0,
        trimTo: t,
        rotation: -90,
      },
      {
        type: 'vstack',
        spacing: 2,
        children: [
          {
            type: 'symbol',
            name: 'flame.fill',
            size: 22,
            color: d.streak > 0 ? color : '#FFFFFF55',
          },
          {
            type: 'text',
            value: String(d.streak),
            size: 28,
            weight: 'heavy',
            design: 'rounded',
            color: '#FFFFFF',
          },
        ],
      },
    ],
  };

  const button = {
    type: 'button',
    action: 'toggleToday',
    children: [
      {
        type: 'symbol',
        name: d.doneToday ? 'checkmark' : 'plus',
        size: 14,
        weight: 'bold',
        color: d.doneToday ? '#0C1821' : '#FFFFFF',
        frame: { width: 30, height: 30 },
        background: d.doneToday ? '#43A047' : '#FFFFFF22',
        clip: 'circle',
      },
    ],
  };

  const ringBlock = {
    type: 'vstack',
    spacing: 8,
    children: [ring, button],
  };

  const cells = d.days.map(x => ({
    type: 'rect',
    cornerRadius: 3,
    fill: x.done ? color : '#FFFFFF22',
    frame: { width: 18, height: 18 },
  }));

  const grid = {
    type: 'vstack',
    spacing: 4,
    children: Array.from({ length: 5 }, (_, r) => ({
      type: 'hstack',
      spacing: 4,
      children: cells.slice(r * 7, r * 7 + 7),
    })),
  };

  const detailBlock = ctx.family === 'medium' && {
    type: 'vstack',
    align: 'leading',
    spacing: 8,
    children: [
      {
        type: 'text',
        value: d.name,
        size: 13,
        weight: 'semibold',
        color: '#FFFFFF',
        lineLimit: 1,
      },
      grid,
    ],
  };

  return {
    type: 'hstack',
    spacing: 16,
    align: 'center',
    padding: 12,
    widgetBackground: '#111418',
    children: [ringBlock, detailBlock],
  };
}
