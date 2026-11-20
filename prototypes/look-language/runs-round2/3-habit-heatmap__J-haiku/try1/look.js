function render(ctx) {
  const d = ctx.data;
  const NEON = '#39FF14';
  const DIM = '#0F2A0F';
  const BG = '#000000';

  const cols = ctx.family === 'medium' ? 14 : 7;
  const rows = 5;
  const days = d.days.slice(-35);
  const cell = ctx.family === 'medium' ? 14 : 16;
  const gap = 3;
  const weeks = [];
  for (let c = 0; c < cols; c++) {
    const week = [];
    for (let r = 0; r < rows; r++) {
      const idx = days.length - 35 + c * 5 + r;
      week.push(days[idx] || { done: false, date: '' });
    }
    weeks.push(week);
  }

  const grid = {
    type: 'hstack',
    spacing: gap,
    children: weeks.map(week => ({
      type: 'vstack',
      spacing: gap,
      children: week.map(day => ({
        type: 'rect',
        cornerRadius: 3,
        fill: day.done ? NEON : DIM,
        frame: { width: cell, height: cell },
      })),
    })),
  };

  const header = {
    type: 'hstack',
    spacing: 6,
    children: [
      { type: 'text', value: d.name, size: 14, weight: 'bold', color: NEON, lineLimit: 1, minScale: 0.6 },
      { type: 'spacer' },
      { type: 'text', value: d.streak + 'd', size: 12, weight: 'semibold', color: NEON },
    ],
  };

  const toggle = {
    type: 'button',
    action: 'toggleToday',
    children: [
      {
        type: 'symbol',
        name: d.doneToday ? 'checkmark.circle.fill' : 'circle',
        size: 16,
        color: NEON,
      },
    ],
  };

  return {
    type: 'vstack',
    align: 'leading',
    spacing: 8,
    padding: 12,
    frame: { maxWidth: 'infinity', maxHeight: 'infinity', alignment: 'topLeading' },
    widgetBackground: BG,
    children: [
      header,
      grid,
      { type: 'hstack', children: [{ type: 'spacer' }, toggle] },
    ],
  };
}
