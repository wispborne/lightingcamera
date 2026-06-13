// Shared subscriber gauge: a live count of active watchers across both fronts (the app
// server's box subscriptions and the web map's viewers). The upstream Blitzortung
// connection stays open regardless; this is just for visibility/logging.

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
