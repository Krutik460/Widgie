const TEAL = '#205962';
const CREAM = '#F2E7CB';
const INK = '#2A2A28';
const MUTED = '#8C8A7E';
const RED = '#C65A3B';

const BARS = [2, 1, 3, 1, 1, 2, 4, 1, 2, 1, 3, 2, 1, 1, 2, 3, 1];

function dots(n) {
  return {
    type: 'hstack',
    spacing: 4,
    children: Array.from({ length: n }, () => ({
      type: 'circle', fill: TEAL, frame: { width: 2, height: 2 },
    })),
  };
}

function render(ctx) {
  const d = ctx.data;
  const med = ctx.family === 'medium';
  const items = d.items || [];
  const boarded = d.total > 0 && d.doneCount >= d.total;
  const shown = items.slice(0, med ? 3 : 2);

  const row = it => ({
    type: 'button',
    action: 'toggleDone',
    rowId: it.id,
    children: [{
      type: 'hstack',
      spacing: 6,
      children: [
        {
          type: 'symbol',
          name: it.done ? 'checkmark.square.fill' : 'square',
          size: 13,
          color: it.done ? RED : TEAL,
        },
        {
          type: 'text',
          value: it.title,
          size: 12,
          weight: 'semibold',
          design: 'monospaced',
          color: it.done ? MUTED : INK,
          strikethrough: it.done,
          lineLimit: 1,
          minScale: 0.6,
        },
      ],
    }],
  });

  const header = {
    type: 'hstack',
    spacing: 6,
    padding: { horizontal: 10, vertical: 5 },
    frame: { maxWidth: 'infinity' },
    background: TEAL,
    children: [
      {
        type: 'text', value: 'BOARDING PASS', size: 10, weight: 'bold',
        design: 'monospaced', color: CREAM, kerning: 1.5, lineLimit: 1, minScale: 0.6,
      },
      { type: 'spacer' },
      med && {
        type: 'text', value: 'TRANS-COASTAL', size: 7, weight: 'medium',
        design: 'monospaced', color: CREAM, kerning: 1, lineLimit: 1,
      },
    ],
  };

  const addBtn = {
    type: 'button',
    action: 'openAdd',
    children: [{
      type: 'symbol', name: 'plus', size: 11, weight: 'bold', color: CREAM,
      frame: { width: 22, height: 22 }, background: TEAL, clip: 'circle',
    }],
  };

  const body = {
    type: 'vstack',
    align: 'leading',
    spacing: 5,
    padding: { horizontal: 10, vertical: 6 },
    frame: { maxWidth: 'infinity', maxHeight: 'infinity', alignment: 'topLeading' },
    children: [
      {
        type: 'text', value: 'TASKS', size: 8, weight: 'semibold',
        design: 'monospaced', color: TEAL, kerning: 1.5,
      },
      shown.map(row),
      items.length === 0 && {
        type: 'text', value: 'Nothing to board', size: 11,
        design: 'monospaced', color: MUTED,
      },
      { type: 'spacer' },
      dots(med ? 28 : 16),
      {
        type: 'hstack',
        align: 'bottom',
        spacing: 8,
        children: [
          {
            type: 'vstack',
            align: 'leading',
            spacing: 1,
            children: [
              {
                type: 'text', value: 'DONE', size: 7, weight: 'semibold',
                design: 'monospaced', color: TEAL, kerning: 1,
              },
              {
                type: 'text', value: d.doneCount + ' / ' + d.total, size: 14,
                weight: 'bold', design: 'monospaced', color: INK,
              },
            ],
          },
          { type: 'spacer' },
          addBtn,
        ],
      },
    ],
  };

  const stamp = {
    type: 'zstack',
    rotation: -12,
    children: [
      {
        type: 'rect',
        cornerRadius: 4,
        stroke: { color: RED, width: 2.5, cap: 'round' },
        frame: { width: med ? 140 : 110, height: med ? 36 : 26 },
      },
      {
        type: 'text', value: 'BOARDED', size: med ? 19 : 13, weight: 'black',
        design: 'monospaced', color: RED, kerning: 2, lineLimit: 1, minScale: 0.6,
      },
    ],
  };

  const stampLayer = {
    type: 'zstack',
    frame: { maxWidth: 'infinity', maxHeight: 'infinity', alignment: 'topTrailing' },
    padding: { top: 8, trailing: 8 },
    opacity: 0.9,
    children: [stamp],
  };

  const bodyLayer = {
    type: 'zstack',
    frame: { maxWidth: 'infinity', maxHeight: 'infinity' },
    children: [body, boarded && stampLayer],
  };

  const stub = {
    type: 'vstack',
    spacing: 6,
    align: 'center',
    padding: { horizontal: 10, vertical: 6 },
    frame: { width: 104, maxHeight: 'infinity' },
    children: [
      {
        type: 'text', value: 'PASSENGER STUB', size: 7, weight: 'semibold',
        design: 'monospaced', color: TEAL, kerning: 1, lineLimit: 1, minScale: 0.6,
      },
      {
        type: 'hstack',
        spacing: 1.5,
        children: BARS.map(w => ({ type: 'rect', fill: INK, frame: { width: w, height: 34 } })),
      },
      {
        type: 'text', value: d.doneCount + '/' + d.total, size: 26, weight: 'bold',
        design: 'monospaced', color: RED, lineLimit: 1, minScale: 0.5,
      },
      {
        type: 'text', value: 'DONE', size: 8, weight: 'semibold',
        design: 'monospaced', color: INK, kerning: 1.5,
      },
    ],
  };

  const content = med
    ? {
        type: 'hstack',
        spacing: 0,
        align: 'top',
        frame: { maxWidth: 'infinity', maxHeight: 'infinity' },
        children: [
          bodyLayer,
          { type: 'rect', fill: TEAL, frame: { width: 1, maxHeight: 'infinity' } },
          stub,
        ],
      }
    : bodyLayer;

  return {
    type: 'vstack',
    align: 'leading',
    spacing: 0,
    frame: { maxWidth: 'infinity', maxHeight: 'infinity' },
    widgetBackground: CREAM,
    children: [header, content],
  };
}
