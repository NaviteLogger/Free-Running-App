import { encodePolyline, haversineM } from './geo.ts';
import type { RawActivity, RawPoint, Split, Summary } from './types.ts';

/**
 * Bump this whenever any number below changes. Every activity records the
 * version it was processed with, so it is always clear what has been redone
 * and what still carries old numbers.
 */
export const PIPELINE_VERSION = 1;

export const SETTINGS = {
  /** Fixes worse than this are ignored. A 60 m fix in a street canyon jumps a block. */
  accuracyGateM: 30,

  /** Steps shorter than this are treated as the phone sitting still and drifting. */
  minStepM: 2,

  /**
   * Climb has to exceed this from the last turning point before it counts.
   *
   * This single number is why a flat lap of a park reports under 10 m instead
   * of 200 m. GPS altitude wanders by several metres between one second and
   * the next, and adding up every rise sums the noise. Waiting for a run of
   * climbing to clear 5 m throws the noise away and keeps real hills.
   */
  elevationThresholdM: 5,

  /** Below this speed the runner is treated as stopped. */
  stoppedSpeedMS: 0.5,

  /**
   * How long a stop has to last before it stops counting as moving time.
   *
   * The rule is that a 60-second wait comes out and a 5-second hesitation at a
   * crossing stays in. Anything between 5 and 60 works; 15 sits in the middle.
   */
  minStopS: 15,

  /** A hole longer than this with no pause event was the operating system. */
  osGapS: 10,

  splitDistanceM: 1000,
} as const;

type UsablePoint = RawPoint & { prevGapS: number; stepM: number; moved: boolean };

export function processActivity(raw: RawActivity): Summary {
  const points = usablePoints(raw.points);
  const pauses = pauseWindows(raw);

  const elevation = elevationChange(points);
  const timing = timeBreakdown(points, pauses);
  const distanceM = points.reduce((total, p) => total + p.stepM, 0);

  const elapsedS = Math.max(0, Math.round((raw.endedAt - raw.startedAt) / 1000));
  const movingS = timing.movingS;

  return {
    activityId: raw.id,
    pipelineVersion: PIPELINE_VERSION,
    startedAt: raw.startedAt,
    endedAt: raw.endedAt,
    distanceM: round(distanceM, 2),
    elapsedS,
    movingS,
    ascentM: round(elevation.ascentM, 2),
    descentM: round(elevation.descentM, 2),
    paceSPerKm: distanceM > 0 && movingS > 0 ? round((movingS / distanceM) * 1000, 2) : 0,
    pointCount: raw.points.length,
    usedPointCount: points.length,
    pausedS: timing.pausedS,
    droppedS: timing.droppedS,
    polyline: encodePolyline(points.filter((p) => p.moved)),
    splits: splits(points, pauses),
  };
}

/**
 * Points that pass the accuracy gate, in sequence order.
 *
 * Every point that clears the gate is kept, including the ones where nothing
 * moved. The step filter marks a point as not having moved and contributes no
 * distance, and that is all it does.
 *
 * Deleting those points instead was a bug. Standing still for a minute deleted
 * sixty fixes, the time analysis then saw one long hole, and a normal rest was
 * reported as a minute of data lost to the operating system. Keeping the points
 * preserves the evidence that fixes were still arriving, which is the whole
 * difference between "the runner stopped" and "the phone was suspended".
 *
 * Sorting by `seq` and not by timestamp is deliberate. Two fixes can share a
 * millisecond, and a sort that has to break ties gives an answer that depends
 * on the sorting algorithm. `seq` is unique, so reprocessing always agrees.
 */
function usablePoints(all: readonly RawPoint[]): UsablePoint[] {
  const sorted = [...all].sort((a, b) => a.seq - b.seq);
  const kept: UsablePoint[] = [];

  let previous: RawPoint | undefined;
  let anchor: RawPoint | undefined;

  for (const point of sorted) {
    if (point.accuracy !== null && point.accuracy > SETTINGS.accuracyGateM) continue;
    if (point.isMocked) continue;

    const prevGapS = previous === undefined ? 0 : (point.gpsTs - previous.gpsTs) / 1000;

    let stepM = 0;
    let moved = false;

    if (anchor === undefined) {
      anchor = point;
      moved = true;
    } else {
      const distance = haversineM(anchor.lat, anchor.lon, point.lat, point.lon);
      // The anchor stays put below the threshold, so a slow walk still adds up
      // over several samples instead of being discarded a metre at a time.
      if (distance >= SETTINGS.minStepM) {
        stepM = distance;
        moved = true;
        anchor = point;
      }
    }

    kept.push({ ...point, prevGapS, stepM, moved });
    previous = point;
  }

  return kept;
}

/** Windows the person deliberately paused, in epoch milliseconds. */
function pauseWindows(raw: RawActivity): { from: number; to: number }[] {
  const ordered = [...raw.events].sort((a, b) => a.seq - b.seq);
  const windows: { from: number; to: number }[] = [];
  let openedAt: number | null = null;

  for (const event of ordered) {
    if (event.kind === 'pause' && openedAt === null) {
      openedAt = event.ts;
    } else if (
      (event.kind === 'resume' || event.kind === 'finish') &&
      openedAt !== null
    ) {
      windows.push({ from: openedAt, to: event.ts });
      openedAt = null;
    }
  }
  // A pause that never reopened ran to the end of the activity.
  if (openedAt !== null) windows.push({ from: openedAt, to: raw.endedAt });

  return windows;
}

/**
 * Milliseconds of the span [from, to] that fall inside a pause.
 *
 * Measured as an overlap and not by testing one timestamp. A gap between two
 * fixes can start before a pause and end after it, which happens every time
 * somebody resumes from standing still: the first fix after resuming has not
 * moved far enough to be kept, so the next kept fix sits just past the resume.
 * Testing a single timestamp blamed that whole gap on the operating system.
 */
function pausedOverlapMs(
  from: number,
  to: number,
  pauses: readonly { from: number; to: number }[],
): number {
  let total = 0;
  for (const window of pauses) {
    const start = Math.max(from, window.from);
    const end = Math.min(to, window.to);
    if (end > start) total += end - start;
  }
  return Math.min(total, Math.max(0, to - from));
}

/**
 * Splits elapsed time into moving, deliberately paused, and lost.
 *
 * The third one is the reason the phone records pause events at all. A hole in
 * the fixes with a pause around it was a choice. The same hole with nothing
 * around it was the operating system suspending the app, and is missing data
 * worth reporting instead of quietly smoothing over.
 */
function timeBreakdown(
  points: readonly UsablePoint[],
  pauses: readonly { from: number; to: number }[],
): { movingS: number; pausedS: number; droppedS: number } {
  let movingS = 0;
  let pausedS = 0;
  let droppedS = 0;

  let stoppedRun = 0;
  // Set once a run of stopped samples has been taken out of moving time, so a
  // long stop is subtracted once and not again on every sample that follows.
  let stopSettled = false;

  for (let i = 1; i < points.length; i++) {
    const point = points[i];
    if (point === undefined) continue;

    const gapS = point.prevGapS;
    if (gapS <= 0) continue;

    const spanTo = point.gpsTs;
    const spanFrom = spanTo - gapS * 1000;
    const pausedPortionS = pausedOverlapMs(spanFrom, spanTo, pauses) / 1000;
    pausedS += pausedPortionS;

    const activeS = gapS - pausedPortionS;
    if (activeS <= 0) {
      stoppedRun = 0;
      continue;
    }

    if (activeS > SETTINGS.osGapS) {
      // Nothing arrived for a while and nobody asked for a pause.
      droppedS += activeS;
      stoppedRun = 0;
      continue;
    }

    const speedMS = point.stepM / activeS;
    if (speedMS < SETTINGS.stoppedSpeedMS) {
      stoppedRun += activeS;
      if (stoppedRun >= SETTINGS.minStopS) {
        if (!stopSettled) {
          // Long enough to be a real stop. Take back the seconds already
          // counted as movement before we knew how long this would last.
          movingS -= Math.min(movingS, stoppedRun - activeS);
          stopSettled = true;
        }
        continue;
      }
      // Might still be a wait at a crossing. Count it for now.
      movingS += activeS;
      continue;
    }

    stoppedRun = 0;
    stopSettled = false;
    movingS += activeS;
  }

  return {
    movingS: Math.max(0, Math.round(movingS)),
    pausedS: Math.round(pausedS),
    droppedS: Math.round(droppedS),
  };
}

/**
 * Total climb and descent, with a threshold so noise does not accumulate.
 *
 * Tracks the last turning point. Climb only counts once the rise from that
 * point clears the threshold, and the direction only flips after an equal move
 * the other way.
 */
function elevationChange(points: readonly UsablePoint[]): {
  ascentM: number;
  descentM: number;
} {
  let ascentM = 0;
  let descentM = 0;

  let pivot: number | null = null;
  let direction: 'up' | 'down' | null = null;

  for (const point of points) {
    const altitude = point.altitude;
    if (altitude === null) continue;

    if (pivot === null) {
      pivot = altitude;
      continue;
    }

    const delta = altitude - pivot;

    if (direction === 'up') {
      if (delta > 0) {
        ascentM += delta;
        pivot = altitude;
      } else if (-delta >= SETTINGS.elevationThresholdM) {
        direction = 'down';
        descentM += -delta;
        pivot = altitude;
      }
      continue;
    }

    if (direction === 'down') {
      if (delta < 0) {
        descentM += -delta;
        pivot = altitude;
      } else if (delta >= SETTINGS.elevationThresholdM) {
        direction = 'up';
        ascentM += delta;
        pivot = altitude;
      }
      continue;
    }

    if (delta >= SETTINGS.elevationThresholdM) {
      direction = 'up';
      ascentM += delta;
      pivot = altitude;
    } else if (-delta >= SETTINGS.elevationThresholdM) {
      direction = 'down';
      descentM += -delta;
      pivot = altitude;
    }
  }

  return { ascentM, descentM };
}

/**
 * One entry per kilometre.
 *
 * Each split's timing starts at its own first point, so the second between the
 * last point of one split and the first of the next belongs to neither. Over a
 * ten-kilometre run that is about nine seconds unaccounted for across the
 * splits. The activity total is measured separately and is correct; only the
 * per-split numbers carry this.
 */
function splits(
  points: readonly UsablePoint[],
  pauses: readonly { from: number; to: number }[],
): Split[] {
  const out: Split[] = [];
  let bucket: UsablePoint[] = [];
  let bucketDistance = 0;
  let index = 1;

  const flush = (): void => {
    if (bucket.length === 0) return;
    const timing = timeBreakdown(bucket, pauses);
    const elevation = elevationChange(bucket);
    out.push({
      index: index++,
      distanceM: round(bucketDistance, 2),
      elapsedS: Math.round(elapsedOf(bucket)),
      movingS: timing.movingS,
      ascentM: round(elevation.ascentM, 2),
      descentM: round(elevation.descentM, 2),
    });
    bucket = [];
    bucketDistance = 0;
  };

  for (const point of points) {
    bucket.push(point);
    bucketDistance += point.stepM;
    if (bucketDistance >= SETTINGS.splitDistanceM) flush();
  }
  flush();

  return out;
}

function elapsedOf(points: readonly UsablePoint[]): number {
  const first = points[0];
  const last = points[points.length - 1];
  if (first === undefined || last === undefined) return 0;
  return (last.gpsTs - first.gpsTs) / 1000;
}

/** Fixed rounding, so the same input always serialises to the same bytes. */
function round(value: number, places: number): number {
  const factor = 10 ** places;
  return Math.round(value * factor) / factor;
}
