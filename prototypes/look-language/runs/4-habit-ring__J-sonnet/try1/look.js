function lerpColor(a, b, t) {
  const pa = [1, 3, 5].map(i => parseInt(a.slice(i, i + 2), 16));
  const pb = [1, 3, 5].map(i => parseInt(b.slice(i, i + 2), 16));
  return '#' + pa.map((v, i) => Math.round(v + (pb[i] - v) * t).toString(16).padStart(2, '0')).join('');
}

function ringColor(t) {
  // red -> yellow -> green
  if (t < 0.5) return lerpColor('#E5484D', '#F5C542', t * 2);
  return lerpColor('#F5C542', '#3DD68C', (t - 0.5) * 2);
}

function render(ctx) {
  const d = ctx.data;
  const streak = Math.max(0, Math.floor(Number(d.streak) || 0));
  const goal = 30;
  const t = Math.min(streak / goal, 1);
  const col = ringColor(t);
  const medium = ctx.family === 'medium';
  const ringSize = medium ? 126 : 112;
  const ringW = medium ? 12 : 11;

  const fillFrac = streak === 0 ? 0 : Math.max(t, 0.03);

  const ring = {
    type: 'zstack',
    frame: { width: ringSize, height: ringSize },
    children: [
      { type: 'circle', stroke: { color: '#FFFFFF1F', width: ringW }, frame: { width: ringSize, height: ringSize } },
      fillFrac > 0 && {
        type: 'circle',
        stroke: { color: col, width: ringW, cap: 'round' },
        trimFrom: 0,
        trimTo: fillFrac,
        rotation: -90,
        frame: { width: ringSize, height: ringSize },
      },
      {
        type: 'vstack',
        spacing: 0,
        children: [
          { type: 'symbol', name: 'flame.fill', size: medium ? 26 : 22, color: streak === 0 ? '#6B7280' : col },
          { type: 'text', value: String(streak), size: medium ? 36 : 32, weight: 'heavy', design: 'rounded', color: '#FFFFFF', lineLimit: 1, minScale: 0.5 },
          { type: 'text', value: streak === 1 ? 'day' : 'days', size: 10, weight: 'medium', color: '#FFFFFF99' },
        ],
      },
    ],
  };

  const ringButton = {
    type: 'button',
    action: 'toggleToday',
    children: [ring],
  };

  const recent = d.days.slice(-14);
  const dots = [recent.slice(0, 7), recent.slice(7)].map(row => ({
    type: 'hstack',
    spacing: 6,
    children: row.map((x, i) => ({
      type: 'circle',
      fill: x.done ? col : '#FFFFFF22',
      frame: { width: 14, height: 14 },
    })),
  }));

  const toggle = {
    type: 'button',
    action: 'toggleToday',
    children: [
      {
        type: 'hstack',
        spacing: 6,
        padding: { horizontal: 12, vertical: 8 },
        background: d.doneToday ? col : '#FFFFFF1F',
        clip: 'capsule',
        children: [
          { type: 'symbol', name: d.doneToday ? 'checkmark.circle.fill' : 'circle', size: 14, weight: 'semibold', color: d.doneToday ? '#0F1720' : '#FFFFFF' },
          { type: 'text', value: d.doneToday ? 'Done today' : 'Mark done', size: 13, weight: 'semibold', color: d.doneToday ? '#0F1720' : '#FFFFFF', lineLimit: 1 },
        ],
      },
    ],
  };

  const bg = { gradient: 'linear', stops: ['#1E2530', '#0F1720'], from: 'top', to: 'bottom' };

  if (!medium) {
    return {
      type: 'vstack',
      spacing: 4,
      padding: 8,
      frame: { maxWidth: 'infinity', maxHeight: 'infinity', alignment: 'center' },
      widgetBackground: bg,
      children: [
        { type: 'text', value: d.name, size: 12, weight: 'semibold', color: '#FFFFFFCC', lineLimit: 1, minScale: 0.7 },
        ringButton,
      ],
    };
  }

  return {
    type: 'hstack',
    spacing: 16,
    padding: 14,
    align: 'center',
    frame: { maxWidth: 'infinity', maxHeight: 'infinity', alignment: 'center' },
    widgetBackground: bg,
    children: [
      ringButton,
      {
        type: 'vstack',
        align: 'leading',
        spacing: 10,
        children: [
          { type: 'text', value: d.name, size: 18, weight: 'bold', color: '#FFFFFF', lineLimit: 1, minScale: 0.6 },
          { type: 'vstack', align: 'leading', spacing: 6, children: dots },
          toggle,
        ],
      },
      { type: 'spacer' },
    ],
  };
}
