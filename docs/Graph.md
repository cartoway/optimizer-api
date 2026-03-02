# Graph

Build and retrieve the proximity graph (Delaunay triangulation, skills/timewindow compatibilities, K-NN) from a VRP instance.

## Endpoint

**POST** `/0.1/vrp/graph`

Same request body as [submit](Home.md#submit). Additional parameters:

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `format` | String | `"json"` | Output format: `"json"` (full graph structure) or `"geojson"` |

## Example request

```bash
curl -X POST "http://localhost:1791/0.1/vrp/graph?api_key=your_key" \
  -H "Content-Type: application/json" \
  -d '{"vrp": {...}}'
```

## Response (format=json)

```json
{
  "nodes": {
    "service_1": {
      "point": {"lat": 48.1, "lon": -1.6},
      "skills": [],
      "timewindows": [{"start": 0, "end": 86400}]
    }
  },
  "edges": [["service_1", "service_2", 120], ...],
  "incompatibilities": [["service_a", "service_b"], ...],
  "knn_neighbors": {
    "service_1": ["service_2", "service_3", ...]
  },
  "metadata": {
    "delaunay_built_at": "2025-01-29T...",
    "matrix_id_used": "..."
  }
}
```

## Response (format=geojson)

Returns a GeoJSON FeatureCollection with Point features for each service and LineString features for each edge.

## Requirements

The `vrp_delaunay` binary must be built: `rake ext:vrp_delaunay`
