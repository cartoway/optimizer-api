# Copyright © Cartoway, 2026
#
require './test/test_helper'

module Interpreters
  class DichoLevelTimingsTest < Minitest::Test
    def test_accumulates_per_level_and_logs_totals
      dicho_data = {}
      DichoLevelTimings.ensure!(dicho_data)
      DichoLevelTimings.record_context!(dicho_data, 0, TestHelper.create(VRP.basic))

      DichoLevelTimings.add!(dicho_data, 0, :split_ms, 100)
      DichoLevelTimings.add!(dicho_data, 1, :children_ms, 200)
      DichoLevelTimings.record_call!(
        dicho_data, 1, total_ms: 50, ruby_ms: 30, solver_ms: 20
      )

      level0 = dicho_data[:level_timings][0]
      level1 = dicho_data[:level_timings][1]

      assert_equal 100, level0[:split_ms]
      assert_equal 200, level1[:children_ms]
      assert_equal 1, level1[:ortools_calls]
      assert_equal 50, level1[:ortools_wall_ms]

      line = DichoLevelTimings.send(:level_line, 'L', 1, level1)
      assert line.start_with?('dicho level timings:')
      refute_empty line
    end

    def test_initialize_split_data_keeps_shared_level_timings
      dicho_data = {}
      DichoLevelTimings.ensure!(dicho_data)
      DichoResolutionTimings.ensure!(dicho_data)
      level_timings_ref = dicho_data[:level_timings]
      resolution_timings_ref = dicho_data[:resolution_timings]

      problem = VRP.lat_lon
      problem[:vehicles] << problem[:vehicles].first.merge(id: 'v_2')
      vrp = TestHelper.create(problem)
      service_vrp = Models::ResolutionContext.new(vrp: vrp, dicho_data: dicho_data)

      split_data, = Interpreters::SplitClustering.initialize_split_data(service_vrp)

      assert_same level_timings_ref, split_data[:level_timings]
      assert_same resolution_timings_ref, split_data[:resolution_timings]
      assert_same dicho_data, service_vrp.dicho_data

      DichoLevelTimings.add!(dicho_data, 0, :split_ms, 42)
      DichoResolutionTimings.add!(dicho_data, :dicho_postprocess_ms, 99)

      assert_equal 42, level_timings_ref[0][:split_ms]
      assert_equal 99, resolution_timings_ref[:dicho_postprocess_ms]
    end
  end
end
