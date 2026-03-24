# VrpGraph

Library for building and using Delaunay-based proximity graphs for VRP instances.

## Features

- **Delaunay triangulation** of service points via Spade (Rust extension)
- **Skills compatibility**: mark service pairs incompatible when no vehicle can serve both
- **Timewindow compatibility**: mark pairs incompatible when travel time + duration makes sequencing infeasible
- **K-Nearest Neighbors**: enrich neighborhood using travel time matrix, filtered by compatibility
- **GeoJSON export**: visualize the graph
- **Batch assignment**: group routes into lots (max size constraint) favoring proximity

## Usage

```ruby
require 'vrp_graph'

# Build graph from VRP
graph = VrpGraph::GraphBuilder.new(vrp).build

# Export to GeoJSON
geojson = graph.to_geojson

# Get connected pairs for each route in a solution
connectivity = graph.tours_connectivity_from_solution(solution)

# Assign routes to batches
assigner = VrpGraph::BatchAssigner.new(graph, solution, max_routes_per_batch: 5)
route_to_batch = assigner.assign
```

## Spade binary (required)

Delaunay triangulation uses a standalone Rust binary (Spade). Build it with:

```bash
rake ext:vrp_delaunay
```

Requires Rust toolchain (cargo). The binary is placed in `exe/vrp_delaunay`.

## Dependencies

- Spade Rust extension (required)
- `rgeo`, `rgeo-geojson` (for GeoJSON export)
- `or-tools` (optional, for CP-based batch assignment)
