/**
 * What the phone uploads. These mirror the on-device tables one for one, so a
 * row read out of the phone's SQLite lands here without reshaping.
 *
 * Nothing in this file is ever written back to. Raw points are stored once and
 * every published number is rebuilt from them.
 */

export type RawPoint = {
  seq: number;
  /** When the fix reached the app. Epoch milliseconds, UTC. */
  ts: number;
  /** When the platform says the fix was taken. Epoch milliseconds, UTC. */
  gpsTs: number;
  lat: number;
  lon: number;
  accuracy: number | null;
  altitude: number | null;
  altitudeAccuracy: number | null;
  speed: number | null;
  speedAccuracy: number | null;
  heading: number | null;
  isMocked: boolean;
  battery: number | null;
};

export type RawEvent = {
  seq: number;
  ts: number;
  /** start, pause, resume, finish, salvage, lifecycle, grants, error, watchdog */
  kind: string;
  detail: Record<string, unknown> | null;
};

export type RawActivity = {
  id: string;
  startedAt: number;
  endedAt: number;
  device: string;
  osVersion: string;
  appVersion: string;
  sampleIntervalMs: number;
  accuracyProfile: string;
  points: RawPoint[];
  events: RawEvent[];
};

export type Split = {
  /** 1 for the first kilometre, and so on. */
  index: number;
  distanceM: number;
  elapsedS: number;
  movingS: number;
  ascentM: number;
  descentM: number;
};

export type Summary = {
  activityId: string;
  pipelineVersion: number;
  startedAt: number;
  endedAt: number;
  distanceM: number;
  elapsedS: number;
  movingS: number;
  ascentM: number;
  descentM: number;
  /** Seconds per kilometre over moving time. Zero when nothing moved. */
  paceSPerKm: number;
  pointCount: number;
  /** Points that survived the accuracy gate. */
  usedPointCount: number;
  /** Seconds inside deliberate pauses. */
  pausedS: number;
  /** Seconds lost to the operating system, with no pause to explain them. */
  droppedS: number;
  polyline: string;
  splits: Split[];
};
