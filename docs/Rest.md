# Rest

Inform about the drivers obligations to have some rest within a route.

A rest with `timewindows` is placed by the solver in that slot.

A rest with `lapse` is a repeating pause of `duration` seconds every `lapse` seconds of work (travel + service).
In the current implementation, travel and service times are inflated by `duration / lapse` for the solver (rounded up). Customer timewindow **starts** are delayed by the same rate from tour start, capped at `duration` (one pause); **ends** and vehicle amplitude stay unchanged. Discrete pauses are then reinserted: after the visit if the lapse is reached during service, before the next drive if travel would complete it (unless that misses the next stop's timewindow). Solvers never receive these rests.

```json
{
  "rests": [{
    "id": "Break-1",
    "timewindows": [{
      "start": 1200,
      "end": 2400
    }],
    "duration": 600
  }]
}
```

```json
{
  "vehicles": [{
    "id": "vehicle_id",
    "router_mode": "car",
    "router_dimension": "time",
    "speed_multiplier": 1.0,
    "timewindow": {
      "start": 0,
      "end": 7200
    },
    "rests_ids": ["Break-1"],
    "start_point_id": "vehicle-start",
    "end_point_id": "vehicle-end",
    "cost_fixed": 0.0,
    "cost_distance_multiplier": 0.0,
    "cost_time_multiplier": 1.0
  }]
}
```

Repeating regulatory pause (45 minutes every 6 hours of work):

```json
{
  "rests": [{
    "id": "Break-regulatory",
    "duration": 2700,
    "lapse": 21600
  }]
}
```
