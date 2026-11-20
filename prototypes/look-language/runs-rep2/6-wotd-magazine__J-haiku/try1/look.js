function render(ctx) {
  const d = ctx.data;
  const CREAM = '#F5EEDC';
  const INK = '#2A1412';
  const RED = '#8B1E1E';
  const MUTED = '#6B4E48';
  const med = ctx.family === 'medium';
  const word = String(d.word || '');
  const initial = word.charAt(0).toUpperCase();
  const rest = word.slice(1);

  const bigLetter = {
    type: 'text',
    value: initial,
    size: med ? 120 : 92,
    weight: 'bold',
    design: 'serif',
    color: RED,
    lineLimit: 1,
    minScale: 0.5,
  };

  const titleRow = {
    type: 'hstack',
    spacing: 0,
    children: [
      { type: 'text', value: rest, size: med ? 26 : 20, weight: 'semibold', design: 'serif', color: INK, lineLimit: 1, minScale: 0.5 },
    ],
  };

  const pos = {
    type: 'text',
    value: String(d.partOfSpeech || '').toUpperCase(),
    size: 9,
    weight: 'semibold',
    design: 'serif',
    color: RED,
    kerning: 2,
    lineLimit: 1,
  };

  const rule = { type: 'rect', fill: RED, frame: { width: 28, height: 1 } };

  const definition = {
    type: 'text',
    value: String(d.definition || ''),
    size: med ? 12 : 11,
    design: 'serif',
    color: INK,
    lineLimit: med ? 3 : 4,
    minScale: 0.7,
    align: 'leading',
  };

  const example = {
    type: 'text',
    value: String(d.example || ''),
    size: med ? 11 : 10,
    design: 'serif',
    italic: true,
    color: MUTED,
    lineLimit: med ? 2 : 3,
    minScale: 0.7,
    align: 'leading',
  };

  const dateLine = {
    type: 'text',
    value: String(d.date || ''),
    size: 8,
    design: 'serif',
    kerning: 1,
    color: MUTED,
    lineLimit: 1,
  };

  const textColumn = {
    type: 'vstack',
    align: 'leading',
    spacing: 5,
    children: [
      titleRow,
      pos,
      rule,
      definition,
      example,
    ],
  };

  const body = med
    ? {
        type: 'hstack',
        align: 'top',
        spacing: 14,
        children: [
          { type: 'vstack', align: 'leading', children: [bigLetter] },
          { type: 'vstack', align: 'leading', spacing: 5, frame: { maxWidth: 'infinity', alignment: 'leading' }, children: [textColumn] },
        ],
      }
    : {
        type: 'vstack',
        align: 'leading',
        spacing: 2,
        children: [
          bigLetter,
          textColumn,
        ],
      };

  return {
    type: 'vstack',
    align: 'leading',
    padding: 14,
    frame: { maxWidth: 'infinity', maxHeight: 'infinity', alignment: 'topLeading' },
    widgetBackground: CREAM,
    children: [
      body,
      { type: 'spacer' },
      dateLine,
    ],
  };
}
