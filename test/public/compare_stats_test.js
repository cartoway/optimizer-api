const assert = require('assert');
const {
  compareStats, groupUnassignedReasons, formatDuration, formatKm, formatDelta, formatElapsedMs, deltaTone
} = require('../../public/js/compare.js');

const solution = {
  name: 'cart_c352_demo',
  solvers: ['vroom'],
  interpreters: ['split', 'dichotomous'],
  heuristic_synthesis: [{ heuristic: 'global_cheapest_arc' }],
  elapsed: 30919.055852,
  iterations: 42,
  unassigned: [
    { service_id: 'a', reason: 'No vehicle available for this service' },
    { service_id: 'b', reason: 'No vehicle available for this service' },
    { service_id: 'c', reason: 'Cannot be performed due to timewindows' }
  ],
  total_distance: 733000,
  total_travel_time: 18 * 3600,
  total_waiting_time: 0,
  total_time: 18 * 3600 + 54 * 60,
  cost: 2504.63,
  routes: [{
    start_time: 0,
    end_time: 18 * 3600 + 54 * 60,
    activities: [
      { type: 'depot' },
      { type: 'service', detail: { duration: 9 * 60 } },
      { type: 'rest', detail: { duration: 45 * 60 } }
    ]
  }, {
    start_time: 100,
    end_time: 100,
    activities: [{ type: 'service', service_id: 'a', detail: { duration: 0 } }]
  }]
};

const stats = compareStats(solution);
assert.strictEqual(stats.distance, 733000);
assert.strictEqual(stats.driving, 18 * 3600);
assert.strictEqual(stats.waiting, 0);
assert.strictEqual(stats.visits, 9 * 60);
assert.strictEqual(stats.pauses, 45 * 60);
assert.strictEqual(stats.stops, 2);
assert.strictEqual(stats.vehicles, 2);
assert.strictEqual(stats.work, 18 * 3600 + 9 * 60);
assert.strictEqual(stats.tour, 18 * 3600 + 54 * 60);
assert.strictEqual(stats.cost, 2504.63);
assert.strictEqual(stats.solvers, 'vroom');
assert.strictEqual(stats.interpreters, 'split, dichotomous');
assert.strictEqual(stats.heuristics, 'global_cheapest_arc');
assert.strictEqual(stats.elapsed, 30919.055852);
assert.strictEqual(stats.iterations, 42);
assert.strictEqual(stats.unassigned, 3);
assert.strictEqual(
  stats.unassigned_reasons,
  'No vehicle available for this service (2), Cannot be performed due to timewindows (1)'
);
assert.deepStrictEqual(groupUnassignedReasons({ unassigned: [] }), { count: 0, reasons: null });

assert.strictEqual(formatElapsedMs(30919.055852), '30,9 s');
assert.strictEqual(formatDuration(18 * 3600 + 54 * 60), '18:54');
assert.strictEqual(formatDuration(45 * 60), '00:45');
assert.strictEqual(formatKm(733000), '733 km');
assert.strictEqual(formatKm(62900), '62,9 km');
assert.strictEqual(formatDelta('km', 62900), '+62,9 km');
assert.strictEqual(formatDelta('duration', 46 * 60), '+00:46');
assert.strictEqual(formatDelta('duration', -46 * 60), '-00:46');
assert.strictEqual(formatDelta('money', 0), '\u2014');
assert.strictEqual(deltaTone({ higherIsWorse: true }, 796000, 733000), 'worse');
assert.strictEqual(deltaTone({ higherIsWorse: true }, 10, 10), 'same');
assert.strictEqual(deltaTone({ higherIsWorse: true }, 5, 10), 'better');

console.log('ok');
