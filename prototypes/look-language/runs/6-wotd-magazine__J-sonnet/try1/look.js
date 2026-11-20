function formatDate(s) {
  const months = ['JAN','FEB','MAR','APR','MAY','JUN','JUL','AUG','SEP','OCT','NOV','DEC'];
  const p = String(s || '').split('-');
  if (p.length !== 3) return String(s || '');
  const m = parseInt(p[1], 10);
  const d = parseInt(p[2], 10);
  if (!(m >= 1 && m <= 12) || !(d >= 1)) return String(s);
  return months[m - 1] + ' ' + d;
}

function render(ctx) {
  const d = ctx.data;
  const medium = ctx.family === 'medium';
  const CREAM = '#F6EEDC';
  const RED = '#8B1A1F';
  const DEEP = '#5E0F14';

  const word = String(d.word || '');
  const first = word.charAt(0).toUpperCase();
  const rest = word.slice(1);

  const bigLetter = {
    type: 'text',
    value: first,
    size: medium ? 96 : 70,
    weight: 'bold',
    design: 'serif',
    color: RED,
    lineLimit: 1,
    frame: { alignment: 'topLeading' },
  };

  const wordLine = {
    type: 'text',
    value: rest,
    size: medium ? 26 : 19,
    weight: 'semibold',
    design: 'serif',
    color: DEEP,
    lineLimit: 1,
    minScale: 0.5,
  };

  const pos = {
    type: 'text',
    value: String(d.partOfSpeech || '').toLowerCase(),
    size: 12,
    italic: true,
    design: 'serif',
    color: RED,
    lineLimit: 1,
  };

  const rule = {
    type: 'rect',
    fill: RED,
    frame: { height: 1.5, maxWidth: 'infinity' },
  };

  const definition = {
    type: 'text',
    value: d.definition,
    size: medium ? 13 : 11,
    design: 'serif',
    color: '#2B1A15',
    lineLimit: medium ? 3 : 4,
    minScale: 0.8,
  };

  const example = {
    type: 'text',
    value: '\u201C' + String(d.example || '') + '\u201D',
    size: 11,
    italic: true,
    design: 'serif',
    color: '#7A5A50',
    lineLimit: 2,
    minScale: 0.85,
  };

  const masthead = {
    type: 'hstack',
    spacing: 6,
    children: [
      { type: 'text', value: 'WORD OF THE DAY', size: 8, weight: 'bold', design: 'serif', kerning: 1.5, color: RED, lineLimit: 1 },
      { type: 'spacer' },
      { type: 'text', value: formatDate(d.date), size: 8, weight: 'semibold', design: 'serif', kerning: 1, color: '#9A7B6E', lineLimit: 1 },
    ],
  };

  const titleRow = {
    type: 'hstack',
    align: 'firstBaseline',
    spacing: 0,
    children: [
      bigLetter,
      {
        type: 'vstack',
        align: 'leading',
        spacing: 2,
        padding: { leading: 1 },
        children: [wordLine, pos],
        frame: { alignment: 'leading' },
      },
      { type: 'spacer' },
    ],
  };

  const body = medium
    ? {
        type: 'vstack',
        align: 'leading',
        spacing: 6,
        children: [definition, example],
      }
    : {
        type: 'vstack',
        align: 'leading',
        spacing: 4,
        children: [definition],
      };

  return {
    type: 'vstack',
    align: 'leading',
    spacing: medium ? 4 : 3,
    padding: { top: 12, bottom: 12, leading: 15, trailing: 15 },
    frame: { maxWidth: 'infinity', maxHeight: 'infinity', alignment: 'topLeading' },
    widgetBackground: { gradient: 'linear', stops: [CREAM, '#EADCC0'], from: 'top', to: 'bottom' },
    children: [
      masthead,
      rule,
      {
        type: 'hstack',
        align: 'top',
        spacing: 0,
        frame: { height: medium ? 84 : 60, alignment: 'topLeading' },
        children: [
          {
            type: 'text',
            value: first,
            size: medium ? 84 : 58,
            weight: 'bold',
            design: 'serif',
            color: RED,
            lineLimit: 1,
            padding: { top: medium ? -14 : -10 },
          },
          {
            type: 'vstack',
            align: 'leading',
            spacing: 1,
            padding: { leading: 3, top: medium ? 18 : 12 },
            children: [wordLine, pos],
          },
          { type: 'spacer' },
        ],
      },
      body,
      { type: 'spacer' },
    ],
  };
}
