# Copyright © Cartoway, 2026
#
require './test/test_helper'
require './lib/heuristics/dicho_end_stage_solver.rb'

module Interpreters
  class DichoEndStageSolverTest < Minitest::Test
    def setup
      @vrp = TestHelper.create(VRP.toy)
      @service_vrp = Models::ResolutionContext.new(vrp: @vrp, dicho_level: 0, dicho_data: {})
      DichoResolutionTimings.ensure!(@service_vrp.dicho_data)
    end

    def solution_with_unassigned(count)
      Models::Solution.new(
        unassigned_stops: @vrp.services.first(count).map{ |service| Models::Solution::Stop.new(service) }
      )
    end

    def test_end_stage_enabled_by_default
      assert DichoEndStageSolver.end_stage_active?(@service_vrp, solution_with_unassigned(5))
    end

    def test_end_stage_skips_when_explicitly_disabled
      @vrp.configuration.resolution.dicho_end_stage_enabled = false

      refute DichoEndStageSolver.end_stage_active?(@service_vrp, solution_with_unassigned(5))
      assert_equal 1, DichoResolutionTimings.for_dicho_data(@service_vrp.dicho_data)[:end_stage_skipped_count]
    end

    def test_end_stage_runs_at_intermediate_level
      @service_vrp.dicho_level = 2

      assert DichoEndStageSolver.end_stage_active?(@service_vrp, solution_with_unassigned(5))
    end

    def test_end_stage_skips_when_time_budget_exhausted
      @service_vrp.dicho_data[:end_stage_time_budget_ms] = DichoEndStageSolver::MIN_SOLVE_DURATION_MS
      @service_vrp.dicho_data[:end_stage_time_budget_initial_ms] = 1000

      refute DichoEndStageSolver.end_stage_active?(@service_vrp, solution_with_unassigned(5))
      assert_equal 1, DichoResolutionTimings.for_dicho_data(@service_vrp.dicho_data)[:end_stage_skipped_count]
    end

    def test_reserve_time_budget_splits_duration_at_root
      @vrp.configuration.resolution.duration = 2_100_000
      @vrp.configuration.resolution.dicho_end_stage_time_share = 0.2
      @service_vrp.resolution_time_budget_ms = 2_100_000

      DichoEndStageSolver.reserve_time_budget!(@service_vrp)

      assert_equal 420_000, @service_vrp.dicho_data[:end_stage_time_budget_ms]
      assert_equal 420_000, @service_vrp.dicho_data[:end_stage_time_budget_initial_ms]
      assert_equal 1_680_000, @service_vrp.resolution_time_budget_ms
    end

    def test_reserve_time_budget_skipped_when_share_nil
      @vrp.configuration.resolution.dicho_end_stage_time_share = nil
      @service_vrp.resolution_time_budget_ms = 2_100_000

      DichoEndStageSolver.reserve_time_budget!(@service_vrp)

      refute @service_vrp.dicho_data.key?(:end_stage_time_budget_ms)
      assert_equal 2_100_000, @service_vrp.resolution_time_budget_ms
    end

    def test_consume_end_stage_elapsed_ignores_without_dedicated_pool
      @service_vrp.resolution_time_budget_ms = 50_000

      DichoEndStageSolver.consume_end_stage_elapsed!(@service_vrp, 3000)

      assert_equal 50_000, @service_vrp.resolution_time_budget_ms
    end

    def test_consume_end_stage_elapsed_uses_dedicated_pool
      @service_vrp.dicho_data[:end_stage_time_budget_ms] = 10_000
      @service_vrp.dicho_data[:end_stage_time_budget_initial_ms] = 10_000
      @service_vrp.resolution_time_budget_ms = 50_000

      DichoEndStageSolver.consume_end_stage_elapsed!(@service_vrp, 3000)

      assert_in_delta 7000, @service_vrp.dicho_data[:end_stage_time_budget_ms], 0.01
      assert_in_delta 3000, @service_vrp.dicho_data[:end_stage_wall_consumed_ms], 0.01
      assert_equal 50_000, @service_vrp.resolution_time_budget_ms
    end

    def test_end_stage_skips_when_deadline_reached
      @service_vrp.dicho_data[:resolution_deadline_monotonic] =
        Process.clock_gettime(Process::CLOCK_MONOTONIC) - 1

      refute DichoEndStageSolver.end_stage_active?(@service_vrp, solution_with_unassigned(5))
      assert_equal 1, DichoResolutionTimings.for_dicho_data(@service_vrp.dicho_data)[:end_stage_skipped_count]
    end

    def test_cap_end_stage_solve_duration_respects_deadline
      @service_vrp.dicho_data[:end_stage_time_budget_ms] = 20_000
      @service_vrp.dicho_data[:end_stage_time_budget_initial_ms] = 20_000
      @service_vrp.dicho_data[:resolution_deadline_monotonic] =
        Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2

      assert_equal 2000, DichoEndStageSolver.cap_end_stage_solve_duration!(@service_vrp, 20_000)
    end

    def test_resolution_deadline_reached
      @service_vrp.dicho_data[:resolution_deadline_monotonic] =
        Process.clock_gettime(Process::CLOCK_MONOTONIC) + 0.05

      assert DichoEndStageSolver.resolution_deadline_reached?(@service_vrp)
    end

    def test_cap_end_stage_solve_duration_without_dedicated_pool
      assert_equal 20_000, DichoEndStageSolver.cap_end_stage_solve_duration!(@service_vrp, 20_000)
    end

    def test_cap_end_stage_solve_duration_respects_remaining_budget
      @service_vrp.dicho_data[:end_stage_time_budget_ms] = 5000
      @service_vrp.dicho_data[:end_stage_time_budget_initial_ms] = 5000

      assert_equal 5000, DichoEndStageSolver.cap_end_stage_solve_duration!(@service_vrp, 20_000)
      assert_nil DichoEndStageSolver.cap_end_stage_solve_duration!(@service_vrp, 100)
    end

    def test_insert_counters
      DichoEndStageSolver.record_insert_attempt!(@service_vrp.dicho_data)
      DichoEndStageSolver.record_insert_success!(@service_vrp.dicho_data)
      DichoEndStageSolver.record_insert_rejected!(@service_vrp.dicho_data)
      DichoEndStageSolver.record_insert_no_result!(@service_vrp.dicho_data)
      DichoEndStageSolver.record_inserted!(@service_vrp.dicho_data, 2)

      stored = DichoResolutionTimings.for_dicho_data(@service_vrp.dicho_data)
      assert_equal 1, stored[:end_stage_insert_attempts]
      assert_equal 1, stored[:end_stage_insert_successes]
      assert_equal 1, stored[:end_stage_insert_rejected]
      assert_equal 1, stored[:end_stage_insert_no_result]
      assert_equal 2, stored[:end_stage_services_inserted]
    end
  end
end
