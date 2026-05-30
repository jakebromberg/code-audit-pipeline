import { DiscogsTrack, DiscogsAlbum as Album } from '@wxyc/shared';
import { z } from 'zod';

export type Use = DiscogsTrack | Album;
const _z = z;
