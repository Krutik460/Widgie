function render(ctx) {
  const d = ctx.data;
  const medium = ctx.family === 'medium';
  const items = d.items.slice(0, medium ? 6 : 4);

  const row = (item) => {
    const textColor = item.done ? '#8A7A4A' : '#3B3210';
    return {
      type: 'button',
      action: 'toggleDone',
      rowId: item.id,
      children: [
        {
          type: 'hstack',
          spacing: 6,
          align: 'center',
          children: [
            {
              type: 'symbol',
              name: item.done ? 'checkmark.circle.fill' : 'circle',
              size: 13,
              color: item.done ? '#8A7A4A' : '#3B3210',
            },
            {
              type: 'text',
              value: item.title,
              size: 15,
              design: 'default',
              fontName: 'Marker Felt',
              color: textColor,
              strikethrough: item.done,
              lineLimit: 1,
              minScale: 0.7,
              opacity: item.done ? 0.5 : 1,
            },
          ],
        },
      ],
    };
  };

  const header = {
    type: 'hstack',
    spacing: 4,
    children: [
      {
        type: 'text',
        value: 'To do',
        size: 16,
        fontName: 'Bradley Hand',
        weight: 'bold',
        color: '#3B3210',
      },
      { type: 'spacer' },
      {
        type: 'text',
        value: d.doneCount + '/' + d.total,
        size: 12,
        fontName: 'Bradley Hand',
        color: '#6B5D1E',
      },
    ],
  };

  const note = {
    type: 'vstack',
    align: 'leading',
    spacing: 6,
    padding: 12,
    frame: { maxWidth: 'infinity', maxHeight: 'infinity', alignment: 'topLeading' },
    background: {
      gradient: 'linear',
      stops: ['#FFF59D', '#FFEB3B'],
      from: 'top',
      to: 'bottom',
    },
    shadow: { color: '#00000033', radius: 4, x: 1, y: 2 },
    children: [
      header,
      ...items.map(row),
      { type: 'spacer' },
      {
        type: 'hstack',
        children: [
          { type: 'spacer' },
          {
            type: 'button',
            action: 'openAdd',
            children: [
              {
                type: 'symbol',
                name: 'plus',
                size: 14,
                weight: 'bold',
                color: '#3B3210',
                frame: { width: 26, height: 26 },
                background: '#FFFFFF88',
                clip: 'circle',
              },
            ],
          },
        ],
      },
    ],
  };

  return {
    type: 'zstack',
    rotation: -2,
    widgetBackground: '#FFF9C4',
    children: [note],
  };
}
