// File-path test heuristic: .test.ts → is_test: true on the files.json row.
import { Target } from './target';

export function testTarget(): Target {
  return { id: 'test' };
}
