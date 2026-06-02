// Folder import resolves to <folder>/index.ts; final path is sub-dir/index.ts.
import { IndexExport } from './sub-dir';

export const e: IndexExport = { via: 'index' };
