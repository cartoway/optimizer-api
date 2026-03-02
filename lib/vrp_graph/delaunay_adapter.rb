# frozen_string_literal: true

# Copyright © Cartoway, 2026
#
# This file is part of Cartoway Optimizer.
#
# Cartoway Planner is free software. You can redistribute it and/or
# modify since you respect the terms of the GNU Affero General
# Public License as published by the Free Software Foundation,
# either version 3 of the License, or (at your option) any later version.
#
# Cartoway Optimizer is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY
# or FITNESS FOR A PARTICULAR PURPOSE.  See the Licenses for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with Cartoway Optimizer. If not, see:
# <http://www.gnu.org/licenses/agpl.html>
#
# Delaunay triangulation via Spade Rust binary.
# Requires: rake ext:vrp_delaunay

require 'open3'
require 'json'

module VrpGraph
  module DelaunayAdapter
    BINARY_PATH = File.expand_path('../../exe/vrp_delaunay', __dir__)

    module_function

    # Computes Delaunay triangulation edges from points using Spade.
    # @param points [Array<Array<Float>>] Array of [lon, lat] coordinates
    # @return [Array<Array<Integer>>] Array of [i, j] index pairs for each undirected edge (i < j)
    # @raise [LoadError] if vrp_delaunay binary is not built
    def compute_edges(points)
      return [] if points.size < 2

      unless File.executable?(BINARY_PATH)
        raise LoadError, "vrp_delaunay binary not found. Run: rake ext:vrp_delaunay (expected: #{BINARY_PATH})"
      end

      input = points.map { |lon, lat| [lon.to_f, lat.to_f] }.to_json
      out, err, status = Open3.capture3(BINARY_PATH, stdin_data: input)

      unless status.success?
        raise "vrp_delaunay failed: #{err.presence || out}"
      end

      JSON.parse(out)
    end
  end
end
