// 3d-force-graph ships its own .d.ts, but it types the default export as a
// non-callable `IForceGraph3D` interface, while the documented runtime usage is
// `ForceGraph3D()(domEl)` — a factory that returns a chainable graph. vue-tsc
// rejects the factory call (TS2348). Override the module to the actual callable
// shape so the panel compiles without `as any` gymnastics at the call site.
declare module '3d-force-graph' {
  const ForceGraph3D: () => (el: HTMLElement) => any
  export default ForceGraph3D
}
