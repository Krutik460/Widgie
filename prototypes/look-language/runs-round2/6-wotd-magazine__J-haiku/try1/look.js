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
    size: isMedium ? 120 : 92,
    weight: 'bold',
    design: 'serif',
    color: red,
    lineLimit: 1,
    minScale: 0.5,
  };

  const titleBlock = {
    type: 'vstack',
    align: 'leading',
    spacing: 2,
    children: [
      { type: 'text', value: word, size: isMedium ? 22 : 18, weight: 'bold', design: 'serif', italic: true, color: ink, lineLimit: 1, minScale: 0.5 },
      { type: 'text', value: d.partOfSpeech || '', size: 10, weight: 'semibold', design: 'serif', italic: true, color: red, lineLimit: 1 },
    ],
  };

  const rule = { type: 'rect', fill: red, frame: { height: 1 } };

  const definition = {
    type: 'text',
    value: d.definition || '',
    size: isMedium ? 12 : 11,
    design: 'serif',
    color: ink,
    lineLimit: isMedium ? 4 : 5,
    minScale: 0.7,
    align: 'leading',
  };

  const example = isMedium
    ? { type: 'text', value: '\u201C' + (d.example || '') + '\u201D', size: 11, design: 'serif', italic: true, color: '#5A3B3B', lineLimit: 2, minScale: 0.7, align: 'leading' }
    : null;

  const date = {
    type: 'text',
    value: d.date || '',
    size: 9,
    design: 'serif',
    color: red,
    kerning: 1,
  };

  const textColumn = {
    type: 'vstack',
    align: 'leading',
    spacing: 6,
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
        spacing: 4,
        children: [
          { type: 'hstack', align: 'bottom', spacing: 8, children: [dropCap, { type: 'spacer' }] },
          textColumn,
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
