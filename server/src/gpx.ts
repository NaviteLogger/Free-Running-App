import { XMLParser } from 'fast-xml-parser';

import type { RawActivity, RawEvent, RawPoint } from './pipeline/types.ts';

/**
 * GPX in and out.
 *
 * Export exists so leaving this app is as easy as leaving Strava was. Import
 * exists so a Strava bulk export can be brought in, and because a system that
 * can only read its own files is a trap.
 */

const GPX_NS = 'http://www.topografix.com/GPX/1/1';

export function toGpx(raw: RawActivity, name?: string): string {
  const pauses = pauseWindows(raw);
  const segments = splitOnPauses(raw.points, pauses);

  const body = segments
    .map(
      (segment) => `    <trkseg>\n${segment.map(trackPoint).join('\n')}\n    </trkseg>`,
    )
    .join('\n');

  return [
    '<?xml version="1.0" encoding="UTF-8"?>',
    `<gpx version="1.1" creator="free-running" xmlns="${GPX_NS}">`,
    '  <metadata>',
    `    <time>${iso(raw.startedAt)}</time>`,
    '  </metadata>',
    '  <trk>',
    `    <name>${escapeXml(name ?? defaultName(raw))}</name>`,
    body,
    '  </trk>',
    '</gpx>',
    '',
  ].join('\n');
}

function trackPoint(point: RawPoint): string {
  const parts = [
    `      <trkpt lat="${point.lat.toFixed(7)}" lon="${point.lon.toFixed(7)}">`,
  ];
  if (point.altitude !== null)
    parts.push(`        <ele>${point.altitude.toFixed(2)}</ele>`);
  parts.push(`        <time>${iso(point.gpsTs)}</time>`);
  parts.push('      </trkpt>');
  return parts.join('\n');
}

/**
 * A pause becomes a new track segment, which is what GPX segments are for: a
 * break in continuous recording. Anything reading the file back then knows not
 * to draw a straight line across the gap.
 */
function splitOnPauses(
  points: readonly RawPoint[],
  pauses: readonly { from: number; to: number }[],
): RawPoint[][] {
  if (points.length === 0) return [];
  const segments: RawPoint[][] = [];
  let current: RawPoint[] = [];

  for (const point of [...points].sort((a, b) => a.seq - b.seq)) {
    const inPause = pauses.some((w) => point.gpsTs >= w.from && point.gpsTs <= w.to);
    if (inPause) {
      if (current.length > 0) {
        segments.push(current);
        current = [];
      }
      continue;
    }
    current.push(point);
  }
  if (current.length > 0) segments.push(current);
  return segments.length > 0 ? segments : [[]];
}

function pauseWindows(raw: RawActivity): { from: number; to: number }[] {
  const windows: { from: number; to: number }[] = [];
  let openedAt: number | null = null;
  for (const event of [...raw.events].sort((a, b) => a.seq - b.seq)) {
    if (event.kind === 'pause' && openedAt === null) openedAt = event.ts;
    else if ((event.kind === 'resume' || event.kind === 'finish') && openedAt !== null) {
      windows.push({ from: openedAt, to: event.ts });
      openedAt = null;
    }
  }
  if (openedAt !== null) windows.push({ from: openedAt, to: raw.endedAt });
  return windows;
}

function defaultName(raw: RawActivity): string {
  return `Run ${new Date(raw.startedAt).toISOString().slice(0, 16).replace('T', ' ')}`;
}

const iso = (ms: number): string => new Date(ms).toISOString();

function escapeXml(value: string): string {
  return value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');
}

export type GpxImportResult =
  { ok: true; raw: RawActivity } | { ok: false; problems: string[] };

/**
 * Reads a GPX file into the same shape an upload produces, so imported runs go
 * through exactly the same processing as recorded ones.
 *
 * The id has to be supplied by the caller, because GPX carries no stable
 * identifier. Deriving one from the file contents makes importing the same file
 * twice idempotent.
 */
export function fromGpx(xml: string, id: string): GpxImportResult {
  const parser = new XMLParser({
    ignoreAttributes: false,
    attributeNamePrefix: '@',
    // A file with one trkpt and a file with many should parse to the same
    // shape, so the code below does not need two paths.
    isArray: (name) => ['trk', 'trkseg', 'trkpt'].includes(name),
  });

  let parsed: unknown;
  try {
    parsed = parser.parse(xml) as unknown;
  } catch (error) {
    return { ok: false, problems: [`not valid XML: ${String(error)}`] };
  }

  const gpx = (parsed as Record<string, unknown>)['gpx'];
  if (typeof gpx !== 'object' || gpx === null) {
    return { ok: false, problems: ['no <gpx> element'] };
  }

  const tracks = (gpx as Record<string, unknown>)['trk'];
  if (!Array.isArray(tracks) || tracks.length === 0) {
    return { ok: false, problems: ['no <trk> element'] };
  }

  const points: RawPoint[] = [];
  const events: RawEvent[] = [];
  let seq = 0;
  let eventSeq = 0;

  for (const track of tracks) {
    const segments = (track as Record<string, unknown>)['trkseg'];
    if (!Array.isArray(segments)) continue;

    for (const [index, segment] of segments.entries()) {
      const rawPoints = (segment as Record<string, unknown>)['trkpt'];
      if (!Array.isArray(rawPoints)) continue;

      // A break between segments is a break in recording. Recording it as a
      // pause keeps the processing from treating it as data the OS lost.
      if (index > 0 && points.length > 0) {
        const previous = points[points.length - 1];
        if (previous !== undefined) {
          events.push({
            seq: eventSeq++,
            ts: previous.gpsTs,
            kind: 'pause',
            detail: null,
          });
        }
      }

      for (const item of rawPoints) {
        const point = readTrackPoint(item, seq);
        if (point === null) continue;
        if (
          index > 0 &&
          events.length > 0 &&
          events[events.length - 1]?.kind === 'pause'
        ) {
          events.push({ seq: eventSeq++, ts: point.gpsTs, kind: 'resume', detail: null });
        }
        points.push(point);
        seq++;
      }
    }
  }

  if (points.length === 0) {
    return {
      ok: false,
      problems: ['no track points with a latitude, longitude and time'],
    };
  }

  const first = points[0];
  const last = points[points.length - 1];
  if (first === undefined || last === undefined) {
    return { ok: false, problems: ['no track points'] };
  }

  return {
    ok: true,
    raw: {
      id,
      startedAt: first.gpsTs,
      endedAt: last.gpsTs,
      device: 'imported',
      osVersion: 'imported',
      appVersion: 'gpx-import',
      // Imported files have whatever rate they were recorded at. The median gap
      // is a better guess than pretending it was 1 Hz.
      sampleIntervalMs: medianGapMs(points),
      accuracyProfile: 'unknown',
      points,
      events,
    },
  };
}

function readTrackPoint(item: unknown, seq: number): RawPoint | null {
  if (typeof item !== 'object' || item === null) return null;
  const p = item as Record<string, unknown>;

  const lat = Number(p['@lat']);
  const lon = Number(p['@lon']);
  if (!Number.isFinite(lat) || !Number.isFinite(lon)) return null;
  if (Math.abs(lat) > 90 || Math.abs(lon) > 180) return null;

  const timeText = p['time'];
  const ms = typeof timeText === 'string' ? Date.parse(timeText) : Number.NaN;
  if (!Number.isFinite(ms)) return null;

  const eleValue = Number(p['ele']);
  const altitude = Number.isFinite(eleValue) ? eleValue : null;

  return {
    seq,
    ts: ms,
    gpsTs: ms,
    lat,
    lon,
    // GPX carries no accuracy. Leaving it null means the accuracy gate lets the
    // point through, which is right: there is no evidence it is bad.
    accuracy: null,
    altitude,
    altitudeAccuracy: null,
    speed: null,
    speedAccuracy: null,
    heading: null,
    isMocked: false,
    battery: null,
  };
}

function medianGapMs(points: readonly RawPoint[]): number {
  const gaps: number[] = [];
  for (let i = 1; i < points.length; i++) {
    const a = points[i - 1];
    const b = points[i];
    if (a === undefined || b === undefined) continue;
    const gap = b.gpsTs - a.gpsTs;
    if (gap > 0) gaps.push(gap);
  }
  if (gaps.length === 0) return 1000;
  gaps.sort((a, b) => a - b);
  return gaps[Math.floor(gaps.length / 2)] ?? 1000;
}
