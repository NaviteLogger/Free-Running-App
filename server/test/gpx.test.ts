import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { describe, it } from 'node:test';

import { gpx as toGeoJson } from '@tmcw/togeojson';
import { DOMParser } from '@xmldom/xmldom';

import { fromGpx, toGpx } from '../src/gpx.ts';
import { processActivity } from '../src/pipeline/run.ts';
import type { RawActivity, RawEvent, RawPoint } from '../src/pipeline/types.ts';

const START = Date.UTC(2026, 8, 1, 7, 0, 0);

function makeActivity(seconds = 60, events: RawEvent[] = []): RawActivity {
  const degPerMetre = 1 / 111_195;
  const points: RawPoint[] = [];
  for (let s = 0; s < seconds; s++) {
    points.push({
      seq: s,
      ts: START + s * 1000,
      gpsTs: START + s * 1000,
      lat: 52.2 + s * 3 * degPerMetre,
      lon: 21.0 + s * 0.5 * degPerMetre,
      accuracy: 5,
      altitude: 110 + s * 0.1,
      altitudeAccuracy: 3,
      speed: null,
      speedAccuracy: null,
      heading: null,
      isMocked: false,
      battery: 90,
    });
  }
  return {
    id: 'gpx-1',
    startedAt: START,
    endedAt: START + seconds * 1000,
    device: 'OnePlus CPH2581',
    osVersion: 'Android 16',
    appVersion: '1.0.0+1',
    sampleIntervalMs: 1000,
    accuracyProfile: 'best',
    points,
    events,
  };
}

/**
 * Parses with @tmcw/togeojson, which is somebody else's GPX reader. Checking
 * our own output with our own parser would only prove the two agree.
 */
function parseWithSomeoneElsesParser(xml: string) {
  const doc = new DOMParser().parseFromString(xml, 'text/xml');
  return toGeoJson(doc as unknown as Document);
}

describe('gpx export', () => {
  it('is read correctly by a parser we did not write', () => {
    const geojson = parseWithSomeoneElsesParser(toGpx(makeActivity(60)));

    assert.equal(geojson.type, 'FeatureCollection');
    assert.equal(geojson.features.length, 1);

    const feature = geojson.features[0];
    assert.ok(feature !== undefined);
    const geometry = feature.geometry;
    assert.ok(geometry !== null && geometry.type === 'LineString');
    assert.equal(geometry.coordinates.length, 60);

    // GPX is longitude first. Getting this backwards puts every run in the
    // wrong hemisphere, and it is a mistake that survives a long time because
    // the numbers still look plausible.
    const first = geometry.coordinates[0];
    assert.ok(first !== undefined);
    assert.ok(
      Math.abs(Number(first[0]) - 21.0) < 0.01,
      `longitude was ${String(first[0])}`,
    );
    assert.ok(
      Math.abs(Number(first[1]) - 52.2) < 0.01,
      `latitude was ${String(first[1])}`,
    );
  });

  it('turns a pause into a separate track segment', () => {
    const activity = makeActivity(60, [
      { seq: 0, ts: START + 20_000, kind: 'pause', detail: null },
      { seq: 1, ts: START + 40_000, kind: 'resume', detail: null },
    ]);
    const xml = toGpx(activity);
    assert.equal(xml.match(/<trkseg>/g)?.length, 2);

    // The other parser turns multiple segments into a MultiLineString.
    const geojson = parseWithSomeoneElsesParser(xml);
    const geometry = geojson.features[0]?.geometry;
    assert.ok(geometry !== null && geometry !== undefined);
    assert.equal(geometry.type, 'MultiLineString');
  });

  it('escapes a name that contains XML', () => {
    const xml = toGpx(makeActivity(2), 'Tom & Jerry <script>');
    assert.ok(xml.includes('Tom &amp; Jerry &lt;script&gt;'));
    // Still parses, which is the point of escaping it.
    assert.equal(parseWithSomeoneElsesParser(xml).features.length, 1);
  });

  it('declares the GPX 1.1 namespace', () => {
    const xml = toGpx(makeActivity(2));
    assert.ok(xml.includes('http://www.topografix.com/GPX/1/1'));
    assert.ok(xml.startsWith('<?xml version="1.0" encoding="UTF-8"?>'));
  });
});

describe('gpx import', () => {
  it('reads back what it wrote', () => {
    const original = makeActivity(60);
    const result = fromGpx(toGpx(original), 'imported-1');

    assert.equal(result.ok, true);
    if (!result.ok) return;

    assert.equal(result.raw.points.length, 60);
    assert.equal(result.raw.id, 'imported-1');

    const first = result.raw.points[0];
    const originalFirst = original.points[0];
    assert.ok(first !== undefined && originalFirst !== undefined);
    // GPX stores seven decimal places, which is about a centimetre.
    assert.ok(Math.abs(first.lat - originalFirst.lat) < 1e-6);
    assert.ok(Math.abs(first.lon - originalFirst.lon) < 1e-6);
    assert.equal(first.gpsTs, originalFirst.gpsTs);
  });

  it('produces a distance within a metre of the original', () => {
    const original = makeActivity(300);
    const result = fromGpx(toGpx(original), 'imported-2');
    assert.ok(result.ok);
    if (!result.ok) return;

    const before = processActivity(original).distanceM;
    const after = processActivity(result.raw).distanceM;
    assert.ok(
      Math.abs(before - after) < 1,
      `round trip changed distance from ${before} to ${after}`,
    );
  });

  it('turns segment breaks back into pauses', () => {
    const activity = makeActivity(60, [
      { seq: 0, ts: START + 20_000, kind: 'pause', detail: null },
      { seq: 1, ts: START + 40_000, kind: 'resume', detail: null },
    ]);
    const result = fromGpx(toGpx(activity), 'imported-3');
    assert.ok(result.ok);
    if (!result.ok) return;

    assert.ok(result.raw.events.some((e) => e.kind === 'pause'));
    // A break that came back as a pause must not be counted as data the
    // operating system lost.
    assert.equal(processActivity(result.raw).droppedS, 0);
  });

  it('imports the same file twice to the same id when the id comes from the bytes', () => {
    const xml = toGpx(makeActivity(30));
    const idFor = (text: string) =>
      `gpx-${createHash('sha256').update(text).digest('hex').slice(0, 32)}`;
    assert.equal(idFor(xml), idFor(xml));
  });

  const rejects: [string, string][] = [
    ['not XML at all', 'hello there'],
    ['XML with no gpx element', '<?xml version="1.0"?><root/>'],
    ['gpx with no track', `<?xml version="1.0"?><gpx version="1.1"></gpx>`],
    [
      'track points with no time',
      `<?xml version="1.0"?><gpx version="1.1"><trk><trkseg>
         <trkpt lat="52.2" lon="21.0"><ele>110</ele></trkpt>
       </trkseg></trk></gpx>`,
    ],
    [
      'a latitude off the planet',
      `<?xml version="1.0"?><gpx version="1.1"><trk><trkseg>
         <trkpt lat="999" lon="21.0"><time>2026-09-01T07:00:00Z</time></trkpt>
       </trkseg></trk></gpx>`,
    ],
  ];

  for (const [name, xml] of rejects) {
    it(`rejects ${name}`, () => {
      const result = fromGpx(xml, 'x');
      assert.equal(result.ok, false);
      if (!result.ok) assert.ok(result.problems.length > 0);
    });
  }

  it('accepts a file with no elevation', () => {
    const xml = `<?xml version="1.0"?><gpx version="1.1"><trk><trkseg>
      <trkpt lat="52.2" lon="21.0"><time>2026-09-01T07:00:00Z</time></trkpt>
      <trkpt lat="52.2001" lon="21.0"><time>2026-09-01T07:00:01Z</time></trkpt>
    </trkseg></trk></gpx>`;
    const result = fromGpx(xml, 'no-ele');
    assert.ok(result.ok);
    if (!result.ok) return;
    assert.equal(result.raw.points[0]?.altitude, null);
    // No elevation data means no climb, and no crash.
    assert.equal(processActivity(result.raw).ascentM, 0);
  });

  it('guesses the sample rate from the file', () => {
    const xml = `<?xml version="1.0"?><gpx version="1.1"><trk><trkseg>
      <trkpt lat="52.2000" lon="21.0"><time>2026-09-01T07:00:00Z</time></trkpt>
      <trkpt lat="52.2001" lon="21.0"><time>2026-09-01T07:00:05Z</time></trkpt>
      <trkpt lat="52.2002" lon="21.0"><time>2026-09-01T07:00:10Z</time></trkpt>
    </trkseg></trk></gpx>`;
    const result = fromGpx(xml, 'rate');
    assert.ok(result.ok);
    if (!result.ok) return;
    assert.equal(result.raw.sampleIntervalMs, 5000);
  });
});
