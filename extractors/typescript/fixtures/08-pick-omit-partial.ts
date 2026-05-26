// Fixture: utility types `Pick`, `Omit`, `Partial`, `Promise`, `Array`
// must be excluded from references — only the user-type `UserInput` survives.
// Expected: UserSlice.references = [{name: "UserInput", kind: "type-ref"}].

export interface UserInput {
  id: number;
  name: string;
  age: number;
}

export type UserSlice = Pick<UserInput, 'id' | 'name'>;

export type UserMaybe = Partial<Omit<UserInput, 'age'>>;

export type UserPromise = Promise<Array<UserInput>>;
