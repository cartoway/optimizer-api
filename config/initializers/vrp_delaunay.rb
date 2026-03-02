# frozen_string_literal: true

# Build vrp_delaunay Rust binary at startup if missing (server + workers).
# Graph endpoint returns 501 when binary is absent; this avoids manual rake ext:vrp_delaunay.

require File.expand_path('../../lib/vrp_graph/ensure_binary', __dir__)

VrpGraph::EnsureBinary.ensure_built!
