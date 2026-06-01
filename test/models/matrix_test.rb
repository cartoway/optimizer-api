# Copyright © Cartoway, 2026
#
require './test/test_helper'

module Models
  class MatrixTest < Minitest::Test
    def test_flat_dimension_caches_flattened_array
      matrix = Models::Matrix.new(
        id: 'm0',
        time: [[0, 1], [2, 3]],
        distance: [[0, 10], [20, 30]]
      )

      first = matrix.flat_time
      second = matrix.flat_time

      assert_same first, second
      assert_equal [0, 1, 2, 3], first
    end

    def test_flat_dimension_invalidates_when_matrix_replaced
      matrix = Models::Matrix.new(id: 'm0', time: [[0, 1], [2, 3]])
      first = matrix.flat_time

      matrix.time = [[4, 5], [6, 7]]
      second = matrix.flat_time

      refute_same first, second
      assert_equal [4, 5, 6, 7], second
    end
  end
end
