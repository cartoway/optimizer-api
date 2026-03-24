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
# K-Nearest Neighbors using travel time matrix (point-based), filtering incompatible point pairs.
module VrpGraph
  module KnnNeighborhood
    module_function

    # K-NN for points. Matrix base is always points.
    # knn_matrix: { square: points_matrix, pid_to_point: {} } when square matrix in memory,
    #             or { rectangular: [[...], ...] } when only rectangular (repaired × other) was computed.
    #
    # @param repaired_point_ids [Array<String>] point ids that lost Delaunay edges (rows)
    # @param other_point_ids [Array<String>] other point ids, candidate neighbors (columns)
    # @param knn_matrix [Hash] :square + :pid_to_point for direct lookup, or :rectangular
    # @param point_incompat [Hash, Array] incompatible point pairs
    # @param k [Integer] max neighbors per repaired point
    # @return [Hash] point_id => [neighbor_point_id, ...] sorted by travel time
    def compute_knn_points(repaired_point_ids, other_point_ids, knn_matrix, point_incompat, k: 10)
      incompat_set =
        if point_incompat.is_a?(Hash)
          point_incompat
        else
          point_incompat.to_h { |a, b| [[a.to_s, b.to_s].sort, true] }
        end
      result = {}

      repaired_point_ids.each_with_index do |pid, i|
        neighbors =
          other_point_ids.each_with_index.filter_map do |other_pid, j|
            pair = [pid, other_pid].sort
            next if incompat_set.key?(pair)

            travel = travel_from_matrix(pid, other_pid, i, j, knn_matrix)
            [other_pid, travel]
          end
        neighbors.sort_by!{ |_, t| t }
        result[pid] = neighbors.first(k).map(&:first)
      end
      result
    end

    def travel_from_matrix(pid_a, pid_b, row_idx, col_idx, knn_matrix)
      if knn_matrix[:square] && knn_matrix[:pid_to_point]
        pt_a = knn_matrix[:pid_to_point][pid_a]
        pt_b = knn_matrix[:pid_to_point][pid_b]
        return 0 unless pt_a&.matrix_index && pt_b&.matrix_index

        knn_matrix[:square][pt_a.matrix_index]&.[](pt_b.matrix_index) || 0
      elsif knn_matrix[:rectangular]&.any?
        (knn_matrix[:rectangular][row_idx] || [])[col_idx] || 0
      else
        0
      end
    end
  end
end
