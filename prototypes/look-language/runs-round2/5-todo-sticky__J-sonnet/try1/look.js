function render(ctx) {
  const d = ctx.data;
  const items = d.items || [];
  const small = ctx.family === 'small';
  const maxRows = small ? 4 : 4;
  const shown = items.slice(0, maxRows);
  const INK = '#4A3B12';

  const rows = shown.map(it => ({
    type: 'button',
    action: 'toggleDone',
    rowId: it.id,
    children: [
      {
        type: 'hstack',
        spacing: 6,
        align: 'center',
        frame: { maxWidth: 'infinity', alignment: 'leading' },
        children: [
          it.done
            ? { type: 'symbol', name: 'checkmark.circle.fill', size: 14, color: '#8A7A3A' }
            : { type: 'symbol', name: 'circle', size: 14, color: INK },
          {
            type: 'text',
            value: it.title,
            size: small ? 13 : 15,
            fontName: 'Bradley Hand',
            weight: 'bold',
            color: it.done ? '#8A7A3A' : INK,
            strikethrough: !!it.done,
            lineLimit: 1,
            minScale: 0.7,
            opacity: it.done ? 0.55 : 1,
          },
        ],
        opacity: it.done ? 0.6 : 1,
      },
    ],
  }));

  const note = {
    type: 'vstack',
    align: 'leading',
    spacing: small ? 6 : 7,
    padding: { top: 14, bottom: 10, leading: 14, trailing: 12 },
    frame: { width: small ? 140 : 318, height: 140, alignment: 'topLeading' },
    background: { gradient: 'linear', stops: ['#FFE97A', '#FFDB4D'], from: 'top', to: 'bottom' },
    cornerRadius: 4,
    shadow: { color: '#00000040', radius: 5, x: 1, y: 3 },
    rotation: -3,
    children: [
      {
        type: 'hstack',
        align: 'center',
        children: [
          { type: 'text', value: 'To do', size: small ? 18 : 20, fontName: 'Marker Felt', color: INK },
          { type: 'spacer' },
          { type: 'text', value: d.doneCount + '/' + d.total, size: 13, fontName: 'Bradley Hand', weight: 'bold', color: '#8A7A3A' },
        ],
      },
      { type: 'rect', fill: '#4A3B1233', frame: { height: 1 } },
      rows,
      items.length === 0 && { type: 'text', value: 'All clear!', size: 15, fontName: 'Bradley Hand', color: INK },
      { type: 'spacer' },
      {
        type: 'button',
        action: 'openAdd',
        children: [
          {
            type: 'hstack',
            spacing: 4,
            frame: { maxWidth: 'infinity', alignment: 'trailing' },
            children: [
              { type: 'spacer' },
              { type: 'symbol', name: 'plus', size: 12, weight: 'bold', color: INK },
              { type: 'text', value: 'Add', size: 13, fontName: 'Bradley Hand', weight: 'bold', color: INK },
            ],
          },
        ],
      },
    ],
  };

  return {
    type: 'zstack',
    frame: { maxWidth: 'infinity', maxHeight: 'infinity', alignment: 'center' },
    widgetBackground: { gradient: 'linear', stops: ['#D9C27A', '#C9AE5E'], from: 'top', to: 'bottom' },
    children: [note],
  };
}
