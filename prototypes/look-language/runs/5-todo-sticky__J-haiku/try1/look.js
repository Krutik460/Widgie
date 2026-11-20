function hashStr(s) {
  let h = 0;
  for (let i = 0; i < s.length; i++) {
    h = (h * 31 + s.charCodeAt(i)) | 0;
  }
  return Math.abs(h);
}

function render(ctx) {
  const d = ctx.data;
  const isMedium = ctx.family === 'medium';
  const items = d.items.slice(0, isMedium ? 6 : 4);
  const remaining = d.items.length - items.length;

  const tilt = -2;
  const noteBg = '#FFF176';
  const inkColor = '#3E3A1F';
  const doneInk = '#8C8660';

  const rows = items.map((item, i) => {
    const jitter = (hashStr(item.id) % 5) - 2;
    const tilted = {
      type: 'hstack',
      spacing: 6,
      align: 'center',
      children: [
        {
          type: 'symbol',
          name: item.done ? 'checkmark.circle.fill' : 'circle',
          size: 13,
          color: item.done ? doneInk : inkColor,
        },
        {
          type: 'text',
          value: item.title,
          size: isMedium ? 15 : 14,
          weight: 'medium',
          design: 'rounded',
          italic: true,
          color: item.done ? doneInk : inkColor,
          strikethrough: item.done,
          lineLimit: 1,
          minScale: 0.7,
        },
        { type: 'spacer' },
      ],
    };

    return {
      type: 'button',
      action: 'toggleDone',
      rowId: item.id,
      children: [
        {
          type: 'zstack',
          align: 'leading',
          padding: { vertical: 2 },
          offset: { x: jitter * 0.5, y: 0 },
          rotation: (i % 2 === 0 ? 0.6 : -0.6),
          opacity: item.done ? 0.5 : 1,
          children: [tilted],
        },
      ],
    };
  });

  const footer = remaining > 0
    ? { type: 'text', value: '+' + remaining + ' more', size: 11, italic: true, design: 'serif', color: doneInk }
    : { type: 'text', value: d.doneCount + ' of ' + d.total + ' done', size: 11, italic: true, design: 'serif', color: doneInk };

  const addButton = {
    type: 'button',
    action: 'openAdd',
    children: [
      {
        type: 'symbol',
        name: 'plus',
        size: 12,
        weight: 'bold',
        color: inkColor,
        frame: { width: 24, height: 24 },
        background: '#FFEB3B',
        clip: 'circle',
      },
    ],
  };

  const headerRow = {
    type: 'hstack',
    spacing: 4,
    children: [
      {
        type: 'text',
        value: 'To do',
        size: 18,
        weight: 'bold',
        design: 'rounded',
        italic: true,
        color: inkColor,
      },
      { type: 'spacer' },
      addButton,
    ],
  };

  const noteContent = {
    type: 'vstack',
    align: 'leading',
    spacing: 4,
    padding: { top: 12, bottom: 10, leading: 12, trailing: 12 },
    frame: { maxWidth: 'infinity', maxHeight: 'infinity', alignment: 'topLeading' },
    children: [
      headerRow,
      ...rows,
      { type: 'spacer' },
      footer,
    ],
  };

  const note = {
    type: 'zstack',
    align: 'topLeading',
    frame: { maxWidth: 'infinity', maxHeight: 'infinity' },
    children: [
      {
        type: 'rect',
        fill: noteBg,
        cornerRadius: 2,
        shadow: { color: '#00000033', radius: 4, x: 1, y: 3 },
      },
      noteContent,
    ],
  };

  return {
    type: 'zstack',
    frame: { maxWidth: 'infinity', maxHeight: 'infinity' },
    widgetBackground: '#E8E2D0',
    children: [
      {
        type: 'zstack',
        rotation: tilt,
        frame: { maxWidth: 'infinity', maxHeight: 'infinity' },
        padding: 10,
        children: [note],
      },
    ],
  };
}
