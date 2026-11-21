// RenderBox, which draws for SwiftUI's ImageRenderer, rasterizes some content on the GPU and some on the CPU,
// depending on what it has drawn before in the process, and the two round edge pixels one level apart. Tests
// run in parallel, so the same drawing gave different PNG bytes from run to run. RenderBox's RB_DISABLE_GPU
// switch keeps every render on the CPU, so a render depends only on its drawing. RenderBox reads it once, at
// its first render, so it is set here, when the test bundle loads, before any test runs.

#include <stdlib.h>

__attribute__((constructor)) static void renderOnTheCPU(void) { setenv("RB_DISABLE_GPU", "1", 1); }
