function render(ctx) {
  const d = ctx.data;
  const CREAM = '#F5EBDD';
  const RED = '#7A1C1C';
  const INK = '#2B1B17';
  const medium = ctx.family === 'medium';
  const initial = (d.word || '?').charAt(0).toUpperCase();
  const rest = (d.word || '').slice(1);

  const wordLine = {
    type: 'hstack',
    spacing: 0,
    align: 'firstBaseline',
    children: [
      { type: 'text', value: initial, size: medium ? 96 : 80, weight: 'black', design: 'serif', color: RED, lineLimit: 1 },
      { type: 'text', value: rest, size: medium ? 30 : 24, weight: 'semibold', design: 'serif', color: INK, lineLimit: 1, minScale: 0.5 },
    ],
  };

  const pos = {
    type: 'text',
    value: (d.partOfSpeech || '').toUpperCase(),
    size: 10,
    weight: 'semibold',
    design: 'serif',
    kerning: 2,
    color: RED,
    lineLimit: 1,
  };

  const rule = { type: 'rect', fill: RED, frame: { height: 1 } };

  const definition = {
    type: 'text',
    value: d.definition || '',
    size: medium ? 13 : 12,
    design: 'serif',
    italic: false,
    color: INK,
    lineLimit: medium ? 3 : 4,
    minScale: 0.7,
    align: 'leading',
  };

  const example = {
    type: 'text',
    value: '\u201C' + (d.example || '') + '\u201D',
    size: medium ? 12 : 11,
    design: 'serif',
    italic: true,
    color: '#6B4A3E',
    lineLimit: medium ? 2 : 3,
    minScale: 0.7,
    align: 'leading',
  };

  const dateLine = {
    type: 'text',
    value: d.date || '',
    size: 9,
    design: 'serif',
    kerning: 1,
    color: RED,
    lineLimit: 1,
  };

  const left = {
    type: 'vstack',
    align: 'leading',
    spacing: 4,
    children: [wordLine, pos],
  };

  const body = medium
    ? {
        type: 'hstack',
        align: 'top',
        spacing: 14,
        children: [
          { type: 'vstack', align: 'leading', spacing: 6, frame: { width: 120 }, children: [left, { type: 'spacer' }, dateLine] },
          { type: 'rect', fill: RED, frame: { width: 1 } },
          { type: 'vstack', align: 'leading', spacing: 8, children: [definition, example, { type: 'spacer' }] },
        ],
      }
    : {
        type: 'vstack',
        align: 'leading',
        spacing: 6,
        children: [left, rule, definition, example, { type: 'spacer' }, dateLine],
      };

  return {
    type: 'vstack',
    align: 'leading',
    padding: 14,
    frame: { maxWidth: 'infinity', maxHeight: 'infinity', alignment: 'topLeading' },
    widgetBackground: CREAM,
    children: [body],
  };
}
