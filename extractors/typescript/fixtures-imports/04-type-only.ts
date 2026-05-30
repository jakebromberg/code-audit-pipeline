import type { DiscogsTrack } from '@wxyc/shared';
import { type DiscogsAlbum, formatTitle } from '@wxyc/shared';

export type Pair = [DiscogsTrack, DiscogsAlbum];
export const fmt = formatTitle;
