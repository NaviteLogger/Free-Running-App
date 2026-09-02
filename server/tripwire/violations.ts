import { OnlyAType, realValue } from './types.ts'; // verbatimModuleSyntax

export enum Colours {
  Red,
} // erasableSyntaxOnly

export function implicitAny(x) {
  return x;
} // noImplicitAny

export const nullAssign: number = null; // strictNullChecks

export const indexed: string = ([] as string[])[0]; // noUncheckedIndexedAccess

interface Opt {
  x?: number;
}
export const optProp: Opt = { x: undefined }; // exactOptionalPropertyTypes

export const idx: string = ({} as Record<string, string>).someKey; // noPropertyAccessFromIndexSignature

export function noReturn(flag: boolean): number {
  // noImplicitReturns
  if (flag) {
    return 1;
  }
}

export function fallthrough(n: number): string {
  switch (n) {
    case 1: // noFallthroughCasesInSwitch
      const x = 'one';
      console.log(x);
    case 2:
      return 'two';
    default:
      return 'other';
  }
}

export function unusedParam(used: number, spare: string): number {
  // noUnusedParameters
  return used;
}

export function unusedLocal(): void {
  const neverRead = 42; // noUnusedLocals
}

export function unreachable(): number {
  return 1;
  console.log('never'); // allowUnreachableCode: false
}

export function unusedLabel(): void {
  loop: for (const _ of []) {
    break;
  } // allowUnusedLabels: false
}

class Base {
  greet(): string {
    return 'hi';
  }
}
export class Child extends Base {
  greet(): string {
    return 'yo';
  } // noImplicitOverride
}

export const t: OnlyAType = { id: 'x' };
export const v = realValue;
