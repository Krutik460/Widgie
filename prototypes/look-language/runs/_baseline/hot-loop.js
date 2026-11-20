function render(ctx) {
  let s = 0;
  for (let i = 0; i < 3000000; i++) { s += Math.sqrt(i) % 7; }
  return { type: "text", value: String(Math.round(s)) };
}
