// Stands in for kusdt-open's `@kusdt/core/web`: KaPay's page has already loaded the WebAssembly
// (kusdt-core.html), and entry.ts hands that module to `setCoreLoader`. Nothing here fetches it.
export * from '@kusdt/core/core';
export function loadCore(): never {
  throw new Error('The kUSDT core is loaded by KaPay.');
}
