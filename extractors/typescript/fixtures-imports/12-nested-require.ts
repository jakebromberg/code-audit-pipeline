// `const { a: { b } } = require('pkg')` — every destructured binding is a
// nested pattern. The previous extractor lost the specifier entirely;
// after the fix it falls through to the namespace-form bare require row.
const { a: { b } } = require('@wxyc/nested-require');

export const _b = b;
