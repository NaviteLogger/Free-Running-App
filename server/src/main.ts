// Placeholder so `npm run typecheck` has something to chew on. Replace when the
// server starts for real.
//
// The two lines below are here because they are exactly what
// noUncheckedIndexedAccess changes about everyday code: `argv[2]` is typed
// `string | undefined`, so the check is not optional politeness, it is the
// only way this compiles.

const target: string | undefined = process.argv[2];
const greeting: string = target ?? 'nobody in particular';

console.log(`free-running server, greeting ${greeting}`);
