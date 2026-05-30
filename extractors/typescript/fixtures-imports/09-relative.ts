import { Helper } from './local';
import { Sibling } from '../sibling/foo';
import abs from '/abs/path';

export type Out = Helper | Sibling | typeof abs;
