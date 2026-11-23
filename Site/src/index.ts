// The Worker entry. Everything else lives in site.ts, since an entry module may export only handlers.

import { type Env, handle } from "./site";

export default {
    fetch(request, env, ctx) {
        // Bound, because the runtime refuses `fetch` called with any `this` but the global one.
        return handle(request, env, {
            fetch: (input, init) => fetch(input, init),
            now: () => new Date(),
            defer: (task) => ctx.waitUntil(task),
        });
    },
} satisfies ExportedHandler<Env>;
