function render(ctx) {
  const d = ctx.data;
  const CREAM = '#F5EFE0';
  const RED = '#7A1F24';
  const INK = '#2B1B17';
  const isMedium = ctx.family === 'medium';

  const word = String(d.word || '');
  const initial = word.charAt(0).toUpperCase();
  const rest = word.slice(1);

  const bigLetter = {
    type: 'text',
    value: initial,
    size: isMedium ? 120 : 96,
    weight: 'black',
    design: 'serif',
    color: RED,
    lineLimit: 1,
    minScale: 0.5,
  };

  const wordLine = {
    type: 'hstack',
    spacing: 0,
    align: 'firstBaseline',
    children: [
      { type: 'text', value: rest, size: isMedium ? 26 : 22, weight: 'semibold', design: 'serif', color: INK, lineLimit: 1, minScale: 0.5 },
    ],
  };

  const rule = {
    type: 'rect',
    fill: RED,
    frame: { width: 28, height: 1.5 },
  };

  const pos = {
    type: 'text',
    value: String(d.partOfSpeech || '').toUpperCase(),
    size: 10,
    weight: 'semibold',
    design: 'serif',
    italic: true,
    color: RED,
    lineLimit: 1,
  };

  const definition = {
    type: 'text',
    value: d.definition || '',
    size: isMedium ? 13 : 12,
    design: 'serif',
    color: INK,
    lineLimit: isMedium ? 3 : 4,
    minScale: 0.7,
  };

  const example = {
    type: 'text',
    value: d.example ? '\u201C' + d.example + '\u201D' : '',
    size: isMedium ? 12 : 11,
    design: 'serif',
    italic: true,
    color: '#6B4E45',
    lineLimit: isMedium ? 2 : 3,
    minScale: 0.7,
  };

  const dateLine = {
    type: 'text',
    value: String(d.date || ''),
    size: 9,
    design: 'serif',
    color: RED,
    lineLimit: 1,
  };

  const leftCol = {
    type: 'zstack',
    align: 'topLeading',
    children: [
      bigLetter,
    ],
  };

  const textCol = {
    type: 'vstack',
    align: 'leading',
    spacing: 5,
    children: [
      wordLine,
      pos,
      rule,
      definition,
      example,
    ],
  };

  const body = isMedium
    ? {
        type: 'hstack',
        align: 'top',
        spacing: 12,
        children: [
          leftCol,
          { type: 'vstack', align: 'leading', spacing: 5, frame: { maxWidth: 'infinity' }, children: [wordLine, pos, rule, definition, example] },
        ],
      }
    : {
        type: 'vstack',
        align: 'leading',
        spacing: 6,
        children: [
          { type: 'hstack', align: 'top', spacing: 6, children: [leftCol, { type: 'spacer' }] },
          wordLine,
          pos,
          rule,
          definition,
          example,
        ],
      };

  return {
    type: 'vstack',
    align: 'leading',
    spacing: 6,
    padding: 14,
    frame: { maxWidth: 'infinity', maxHeight: 'infinity', alignment: 'topLeading' },
    widgetBackground: CREAM,
    children: [
      body,
      { type: 'spacer' },
      { type: 'hstack', children: [{ type: 'spacer' }, dateLine] },
    ],
  };
}
