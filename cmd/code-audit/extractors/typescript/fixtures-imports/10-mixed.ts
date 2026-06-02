import defaultExport, { Named, Other as Alias } from '@wxyc/mixed';

export type X = Named | Alias | typeof defaultExport;
