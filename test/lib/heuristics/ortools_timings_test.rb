# Copyright © Cartoway, 2026
#
require './test/test_helper'

module Interpreters
  class OrtoolsTimingsTest < Minitest::Test
    def test_ensure_and_accumulate
      dicho_data = {}
      OrtoolsTimings.ensure!(dicho_data)

      OrtoolsTimings.add!(dicho_data, :build_problem_ms, 12.5)
      OrtoolsTimings.increment!(dicho_data, :calls)

      timings = OrtoolsTimings.for_dicho_data(dicho_data)
      assert_equal 12.5, timings[:build_problem_ms]
      assert_equal 1, timings[:calls]
    end

    def test_solve_accumulates_timings_without_subprocess
      wrapper = Wrappers::Ortools.new(tmp_dir: Dir.tmpdir)
      dicho_data = {}
      vrp = TestHelper.create(VRP.basic)
      vrp.vehicles.each{ |vehicle| vehicle.cost_fixed = 1_000_000 }

      empty_solution = vrp.empty_solution(:ortools, [], false).tap{ |solution| solution.elapsed = 750 }

      wrapper.stub(:run_ortools, lambda { |*_args, **_kwargs|
        empty_solution
      }) do
        wrapper.solve(vrp, nil, nil, timings: dicho_data)
      end

      timings = OrtoolsTimings.for_dicho_data(dicho_data)
      assert_equal 1, timings[:calls]
      assert_equal 0, timings[:heuristic_selection_calls]
      assert_operator timings[:build_problem_ms], :>, 0
      assert_operator timings[:total_ms], :>=, timings[:build_problem_ms]
    end
  end
end
