const INK = '#4A3B12';

function render(ctx) {
  const d = ctx.data;
  const items = d.items || [];
  const maxRows = 4;
  const shown = items.slice(0, maxRows);
  const extra = items.length - shown.length;
  const w = ctx.width - 26;
  const h = ctx.height - 26;

  const header = {
    type: 'hstack',
    spacing: 6,
    children: [
      { type: 'text', value: 'To do', size: 17, weight: 'bold', design: 'rounded', italic: true, color: INK },
      { type: 'text', value: d.doneCount + '/' + d.total, size: 12, weight: 'medium', design: 'rounded', italic: true, color: '#4A3B12AA' },
      { type: 'spacer' },
      {
        type: 'button',
        action: 'openAdd',
        children: [
          {
            type: 'symbol', name: 'plus', size: 12, weight: 'bold', color: INK,
            frame: { width: 24, height: 24 },
            background: '#E8B923',
            clip: 'circle',
          },
        ],
      },
    ],
  };

  const rows = shown.map(it => ({
    type: 'button',
    action: 'toggleDone',
    rowId: it.id,
    children: [
      {
        type: 'hstack',
        spacing: 7,
        align: 'center',
        frame: { maxWidth: 'infinity', alignment: 'leading' },
        opacity: it.done ? 0.4 : 1,
        children: [
          { type: 'symbol', name: it.done ? 'checkmark.circle.fill' : 'circle', size: 14, color: INK },
          {
            type: 'text',
            value: it.title,
            size: 14,
            weight: 'medium',
            design: 'rounded',
            italic: true,
            color: INK,
            strikethrough: !!it.done,
            lineLimit: 1,
            minScale: 0.8,
          },
          { type: 'spacer' },
        ],
      },
    ],
  }));

  const body = items.length === 0
    ? [{ type: 'text', value: 'All clear!', size: 15, design: 'rounded', italic: true, color: '#4A3B12AA' }]
    : rows;

  const note = {
    type: 'vstack',
    align: 'leading',
    spacing: 8,
    padding: { top: 16, bottom: 10, leading: 12, trailing: 12 },
    frame: { width: w, height: h, alignment: 'topLeading' },
    background: { gradient: 'linear', stops: ['#FFE97A', '#FAD94D'], from: 'top', to: 'bottom' },
    cornerRadius: 4,
    shadow: { color: '#00000040', radius: 5, x: 1, y: 3 },
    children: [
      header,
      { type: 'rect', fill: '#4A3B1233', frame: { height: 1 } },
      { type: 'vstack', align: 'leading', spacing: 7, children: body },
      extra > 0 && {
        type: 'text', value: '+' + extra + ' more', size: 11, design: 'rounded', italic: true, color: '#4A3B12AA',
      },
      { type: 'spacer' },
    ],
  };

  const tape = {
    type: 'rect',
    fill: '#FFFFFF66',
    frame: { width: 40, height: 12 },
    rotation: 3,
    offset: { x: 0, y: -(h / 2) + 4 },
  };

  return {
    type: 'zstack',
    align: 'center',
    frame: { maxWidth: 'infinity', maxHeight: 'infinity', alignment: 'center' },
    widgetBackground: { gradient: 'linear', stops: ['#D9CBB0', '#C4B491'], from: 'top', to: 'bottom' },
    children: [
      {
        type: 'zstack',
        align: 'center',
        rotation: -2,
        children: [note, tape],
      },
    ],
  };
}
