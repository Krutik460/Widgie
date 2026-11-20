function lerpColor(a, b, t) {
  const pa = [1, 3, 5].map(i => parseInt(a.slice(i, i + 2), 16));
  const pb = [1, 3, 5].map(i => parseInt(b.slice(i, i + 2), 16));
  return '#' + pa.map((v, i) => Math.round(v + (pb[i] - v) * t).toString(16).padStart(2, '0')).join('');
}

function render(ctx) {
  const d = ctx.data;
  const progress = Math.min(Math.max(d.pagesRead / d.pagesGoal, 0), 1);

  const header = {
    type: 'hstack',
    spacing: 6,
    children: [
      { type: 'text', value: d.title, size: 17, weight: 'bold', design: 'serif', color: '#FFFFFF', lineLimit: 1 },
      { type: 'spacer' },
      d.pagesRead >= d.pagesGoal
        ? { type: 'symbol', name: 'checkmark.seal.fill', size: 16, color: '#7AE582' }
        : { type: 'text', value: Math.round(100 * progress) + '%', size: 13, weight: 'semibold', color: '#9FB3C8' },
    ],
  };

  const bar = {
    type: 'zstack',
    align: 'leading',
    children: [
      { type: 'capsule', fill: '#FFFFFF22', frame: { height: 8 } },
      {
        type: 'capsule',
        fill: lerpColor('#F4A259', '#7AE582', progress),
        frame: { width: (ctx.width - 28) * progress, height: 8 },
      },
    ],
  };

  const columns = d.sessions.map((s, i) => ({
    type: 'vstack',
    spacing: 3,
    children: [
      {
        type: 'rect',
        cornerRadius: 3,
        fill: i === d.sessions.length - 1 ? '#7AE582' : '#5C7C99',
        frame: { width: 10, height: 4 + 36 * Math.min(s.pages, 40) / 40 },
      },
      { type: 'text', value: s.day, size: 9, color: '#9FB3C8' },
    ],
  }));

  const addButton = {
    type: 'button',
    action: 'logPages',
    children: [
      {
        type: 'symbol', name: 'plus', size: 16, weight: 'bold', color: '#0C1821',
        frame: { width: 34, height: 34 }, background: '#7AE582', clip: 'circle',
      },
    ],
  };

  return {
    type: 'vstack',
    align: 'leading',
    spacing: 8,
    padding: 14,
    frame: { maxWidth: 'infinity', maxHeight: 'infinity', alignment: 'topLeading' },
    widgetBackground: { gradient: 'linear', stops: ['#1B2A41', '#0C1821'], from: 'top', to: 'bottom' },
    children: [
      header,
      bar,
      ctx.family === 'medium' && { type: 'text', value: d.pagesRead + ' of ' + d.pagesGoal + ' pages', size: 12, color: '#9FB3C8' },
      {
        type: 'hstack',
        align: 'bottom',
        spacing: 6,
        frame: { maxHeight: 'infinity', alignment: 'bottom' },
        children: [columns, { type: 'spacer' }, addButton],
      },
    ],
  };
}
