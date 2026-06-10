// Shared subscriber gauge. The upstream Blitzortung connection is lazy — held open
// only while someone is watching. Both fronts (the app server's box subscriptions
// and the web map's viewers) feed this one counter so either can wake the upstream.

export function makeSubscriberGauge({ onFirst, onLast } = {}) {
  let count = 0;
  return {
    add() {
      if (++count === 1) onFirst?.();
    },
    remove() {
      if (--count === 0) onLast?.();
    },
    get count() {
      return count;
    },
  };
}
