function lerpColor(a, b, t) {
  const pa = [1, 3, 5].map(i => parseInt(a.slice(i, i + 2), 16));
  const pb = [1, 3, 5].map(i => parseInt(b.slice(i, i + 2), 16));
  return '#' + pa.map((v, i) => Math.round(v + (pb[i] - v) * t).toString(16).padStart(2, '0')).join('');
}

function streakColor(t) {
  if (t < 0.5) return lerpColor('#FF453A', '#FFD60A', t * 2);
  return lerpColor('#FFD60A', '#30D158', (t - 0.5) * 2);
}

function render(ctx) {
  const d = ctx.data;
  const goal = 30;
  const streak = Math.max(0, Number(d.streak) || 0);
  const t = Math.min(streak / goal, 1);
  const color = streakColor(t);
  const medium = ctx.family === 'medium';
  const ringSize = 108;

  const ring = {
    type: 'button',
    action: 'toggleToday',
    children: [
      {
        type: 'zstack',
        frame: { width: ringSize, height: ringSize },
        children: [
          { type: 'circle', stroke: { color: '#FFFFFF1F', width: 11 } },
          t > 0 && {
            type: 'circle',
            stroke: { color: color, width: 11, cap: 'round' },
            trimFrom: 0,
            trimTo: t,
            rotation: -90,
          },
          {
            type: 'vstack',
            spacing: 0,
            align: 'center',
            children: [
              {
                type: 'symbol',
                name: 'flame.fill',
                size: 24,
                color: d.doneToday ? color : '#FFFFFF44',
              },
              {
                type: 'text',
                value: String(streak),
                size: 30,
                weight: 'bold',
                design: 'rounded',
                color: '#FFFFFF',
                lineLimit: 1,
                minScale: 0.5,
              },
              { type: 'text', value: streak === 1 ? 'day' : 'days', size: 10, weight: 'medium', color: '#FFFFFF99' },
            ],
          },
        ],
      },
    ],
  };

  const name = {
    type: 'text',
    value: d.name,
    size: medium ? 17 : 14,
    weight: 'semibold',
    color: '#FFFFFF',
    lineLimit: 1,
    minScale: 0.7,
  };

  const background = { gradient: 'linear', stops: ['#1C1C24', '#0B0B10'], from: 'top', to: 'bottom' };

  if (!medium) {
    return {
      type: 'vstack',
      spacing: 6,
      align: 'center',
      padding: 12,
      frame: { maxWidth: 'infinity', maxHeight: 'infinity', alignment: 'center' },
      widgetBackground: background,
      children: [name, ring],
    };
  }

  const days = (d.days || []).slice(-35);
  const rows = [];
  for (let r = 0; r < 5; r++) {
    const cells = [];
    for (let c = 0; c < 7; c++) {
      const idx = r * 7 + c;
      const day = days[idx];
      if (!day) {
        cells.push({ type: 'rect', cornerRadius: 5, fill: '#FFFFFF0D', frame: { width: 20, height: 20 } });
        continue;
      }
      const isToday = idx === days.length - 1;
      const node = {
        type: 'rect',
        cornerRadius: 5,
        fill: day.done ? color : '#FFFFFF1F',
        frame: { width: 20, height: 20 },
      };
      if (isToday) node.stroke = { color: '#FFFFFF', width: 1.5 };
      cells.push(node);
    }
    rows.push({ type: 'hstack', spacing: 4, children: cells });
  }

  return {
    type: 'hstack',
    spacing: 14,
    align: 'center',
    padding: 14,
    frame: { maxWidth: 'infinity', maxHeight: 'infinity', alignment: 'center' },
    widgetBackground: background,
    children: [
      ring,
      {
        type: 'vstack',
        spacing: 6,
        align: 'leading',
        children: [
          name,
          { type: 'vstack', spacing: 4, align: 'leading', children: rows },
        ],
      },
    ],
  };
}
