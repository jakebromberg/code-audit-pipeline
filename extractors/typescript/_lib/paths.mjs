// paths.mjs
//
// Path classification helpers shared between extractors. The test-path
// detection is normative — see docs/pipeline-contract.md > Test path patterns.

const TEST_DIRS = new Set([
  'tests', 'test', '__tests__', '__test__',
  'spec', '__mocks__', '__fixtures__', 'fixtures', 'e2e',
]);
const TEST_FILE_RE = /\.(test|spec|fixture|fixtures|mock|mocks)\.(tsx|ts|mts|cts)$/;

export function isTestPath(relPath) {
  const segments = relPath.split('/');
  for (let i = 0; i < segments.length - 1; i++) {
    if (TEST_DIRS.has(segments[i])) return true;
  }
  return TEST_FILE_RE.test(segments[segments.length - 1]);
}
