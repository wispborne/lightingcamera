// Blitzortung sends each strike message as an LZW-compressed string.
// This is the canonical decompressor ported from the lightningmaps.org client
// and community implementations (SimonSchick/BlitzortungAPI, homeassistant-blitzortung).
//
// It is UNOFFICIAL and UNDOCUMENTED: if Blitzortung changes the wire format this is
// the function that breaks. It lives here, in the one server we control, on purpose.

/**
 * Decompress a Blitzortung LZW-encoded payload back into its JSON string.
 * @param {string} input raw websocket message text
 * @returns {string} the decompressed JSON string
 */
export function lzwDecode(input) {
  const dict = {};
  const chars = input.split('');
  let currChar = chars[0];
  let oldPhrase = currChar;
  const out = [currChar];
  let code = 256;
  let phrase;
  for (let i = 1; i < chars.length; i++) {
    const currCode = chars[i].charCodeAt(0);
    if (currCode < 256) {
      phrase = chars[i];
    } else {
      phrase = dict[currCode] != null ? dict[currCode] : oldPhrase + currChar;
    }
    out.push(phrase);
    currChar = phrase.charAt(0);
    dict[code] = oldPhrase + currChar;
    code++;
    oldPhrase = phrase;
  }
  return out.join('');
}

/**
 * Parse a raw Blitzortung websocket message into a strike object.
 * Tolerates both already-plain JSON and LZW-compressed payloads.
 * @param {string} raw
 * @returns {object|null} parsed strike, or null if it can't be parsed
 */
export function parseStrikeMessage(raw) {
  // Newer feeds may send plain JSON; older/compressed feeds need LZW first.
  try {
    return JSON.parse(raw);
  } catch {
    // not plain JSON — fall through to decompression
  }
  try {
    return JSON.parse(lzwDecode(raw));
  } catch {
    return null;
  }
}

/**
 * Normalize a parsed Blitzortung strike into the shape we forward to clients.
 * Blitzortung `time` is nanoseconds since the Unix epoch; we emit milliseconds.
 * `delay` is the upstream processing latency in seconds (strike -> publish); the
 * app adds it to each strike's thunder-ring elapsed time.
 * @param {object} strike
 * @returns {{lat:number, lon:number, time:number, delay:number}|null}
 */
export function normalizeStrike(strike) {
  if (!strike || typeof strike.lat !== 'number' || typeof strike.lon !== 'number') {
    return null;
  }
  // time is in nanoseconds; convert to ms. Guard against missing/odd values.
  const timeMs =
    typeof strike.time === 'number' ? Math.round(strike.time / 1e6) : Date.now();
  // delay is already in seconds; clamp out missing/negative values to 0.
  const delay =
    typeof strike.delay === 'number' && strike.delay > 0 ? strike.delay : 0;
  return { lat: strike.lat, lon: strike.lon, time: timeMs, delay };
}
