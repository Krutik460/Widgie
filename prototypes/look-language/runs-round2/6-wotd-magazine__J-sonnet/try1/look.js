function formatDate(s) {
  const months = ['January','February','March','April','May','June','July','August','September','October','November','December'];
  const p = String(s || '').split('-');
  if (p.length < 3) return String(s || '');
  const m = parseInt(p[1], 10);
  const d = parseInt(p[2], 10);
  if (!(m >= 1 && m <= 12) || isNaN(d)) return String(s);
  return months[m - 1].toUpperCase() + ' ' + d;
}

function render(ctx) {
  const d = ctx.data;
  const medium = ctx.family === 'medium';
  const CREAM = '#F6EEDC';
  const RED = '#7A1523';
  const INK = '#3A1A1E';

  const word = String(d.word || '');
  const first = word.charAt(0).toUpperCase();
  const rest = word.slice(1);

  const letterSize = medium ? 96 : 70;

  const dropCap = {
    type: 'text',
    value: first,
    size: letterSize,
    weight: 'bold',
    fontName: 'Didot',
    color: RED,
    lineLimit: 1,
    frame: { alignment: 'topLeading' },
    padding: { top: medium ? -14 : -10 },
  };

  const wordLine = {
    type: 'vstack',
    align: 'leading',
    spacing: 1,
    children: [
      {
        type: 'text',
        value: rest,
        size: medium ? 26 : 20,
        fontName: 'Didot',
        color: RED,
        lineLimit: 1,
        minScale: 0.5,
      },
      {
        type: 'text',
        value: String(d.partOfSpeech || '').toUpperCase(),
        size: 9,
        design: 'serif',
        italic: true,
        kerning: 1.5,
        color: '#9C5A60',
        lineLimit: 1,
      },
    ],
  };

  const header = {
    type: 'hstack',
    align: 'top',
    spacing: 4,
    children: [
      {
        type: 'zstack',
        frame: { height: medium ? 74 : 56 },
        children: [dropCap],
      },
      {
        type: 'vstack',
        align: 'leading',
        spacing: 0,
        padding: { top: medium ? 18 : 10 },
        children: [wordLine],
      },
      { type: 'spacer' },
    ],
  };

  const rule = { type: 'rect', fill: RED, frame: { height: 1 }, opacity: 0.6 };

  const definition = {
    type: 'text',
    value: d.definition,
    size: medium ? 13 : 11,
    design: 'serif',
    color: INK,
    lineLimit: medium ? 3 : 4,
    minScale: 0.8,
  };

  const example = medium && {
    type: 'text',
    value: '\u201C' + String(d.example || '') + '\u201D',
    size: 11,
    design: 'serif',
    italic: true,
    color: '#8A4A50',
    lineLimit: 2,
    minScale: 0.85,
  };

  const footer = {
    type: 'hstack',
    children: [
      {
        type: 'text',
        value: formatDate(d.date),
        size: 8,
        design: 'serif',
        kerning: 1.6,
        color: CREAM,
      },
      { type: 'spacer' },
      {
        type: 'text',
        value: 'WORD OF THE DAY',
        size: 8,
        design: 'serif',
        kerning: 1.6,
        color: CREAM,
        opacity: 0.8,
      },
    ],
    padding: { horizontal: 14, vertical: 5 },
    frame: { maxWidth: 'infinity' },
    background: RED,
  };

  const body = {
    type: 'vstack',
    align: 'leading',
    spacing: medium ? 5 : 4,
    padding: { top: 10, horizontal: 14, bottom: 6 },
    frame: { maxWidth: 'infinity', maxHeight: 'infinity', alignment: 'topLeading' },
    children: [header, rule, definition, example],
  };

  return {
    type: 'vstack',
    spacing: 0,
    frame: { maxWidth: 'infinity', maxHeight: 'infinity' },
    widgetBackground: CREAM,
    children: [body, footer],
  };
}
