function render(ctx) {
  const d = ctx.data;
  const cream = '#F5EEDC';
  const red = '#7A1F1F';
  const ink = '#2A1414';
  const isMedium = ctx.family === 'medium';

  const initial = (d.word || '?').charAt(0).toUpperCase();
  const word = (d.word || '').toLowerCase();

  const dropCap = {
    type: 'text',
    value: initial,
    size: isMedium ? 96 : 54,
    weight: 'bold',
    design: 'serif',
    color: red,
    lineLimit: 1,
    minScale: 0.5,
  };

  const titleBlock = {
    type: 'vstack',
    align: 'leading',
    spacing: 1,
    children: [
      { type: 'text', value: word, size: isMedium ? 22 : 15, weight: 'bold', design: 'serif', italic: true, color: ink, lineLimit: 1, minScale: 0.5 },
      { type: 'text', value: d.partOfSpeech || '', size: isMedium ? 10 : 9, weight: 'semibold', design: 'serif', italic: true, color: red, lineLimit: 1, minScale: 0.6 },
    ],
  };

  const rule = { type: 'rect', fill: red, frame: { height: 1 } };

  const definition = {
    type: 'text',
    value: d.definition || '',
    size: isMedium ? 12 : 10,
    design: 'serif',
    color: ink,
    lineLimit: isMedium ? 4 : 3,
    minScale: 0.6,
    align: 'leading',
  };

  const example = isMedium
    ? { type: 'text', value: '\u201C' + (d.example || '') + '\u201D', size: 11, design: 'serif', italic: true, color: '#5A3B3B', lineLimit: 2, minScale: 0.7, align: 'leading' }
    : null;

  const date = {
    type: 'text',
    value: d.date || '',
    size: isMedium ? 9 : 8,
    design: 'serif',
    color: red,
    kerning: 1,
    lineLimit: 1,
    minScale: 0.6,
  };

  const textColumn = {
    type: 'vstack',
    align: 'leading',
    spacing: 5,
    children: [titleBlock, rule, definition, example, { type: 'spacer' }, date],
  };

  const body = isMedium
    ? {
        type: 'hstack',
        align: 'top',
        spacing: 14,
        children: [
          { type: 'vstack', align: 'leading', children: [dropCap, { type: 'spacer' }] },
          textColumn,
        ],
      }
    : {
        type: 'vstack',
        align: 'leading',
        spacing: 6,
        children: [
          { type: 'hstack', align: 'top', spacing: 8, children: [dropCap, titleBlock, { type: 'spacer' }] },
          { type: 'rect', fill: red, frame: { height: 1 } },
          definition,
          { type: 'spacer' },
          date,
        ],
      };

  return {
    type: 'vstack',
    align: 'leading',
    padding: 14,
    frame: { maxWidth: 'infinity', maxHeight: 'infinity', alignment: 'topLeading' },
    widgetBackground: cream,
    children: [body],
  };
}
