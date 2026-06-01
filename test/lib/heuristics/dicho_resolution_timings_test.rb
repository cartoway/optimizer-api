# Copyright © Cartoway, 2026
#
require './test/test_helper'

module Interpreters
  class DichoResolutionTimingsTest < Minitest::Test
    def test_log_summary_includes_accounted_total
      service_vrp = Models::ResolutionContext.new(vrp: TestHelper.create(VRP.basic), dicho_data: {})
      DichoConstructionTimings.ensure!(service_vrp.dicho_data)
      DichoResolutionTimings.ensure!(service_vrp.dicho_data)
      OrtoolsTimings.ensure!(service_vrp.dicho_data)

      DichoResolutionTimings.add!(service_vrp.dicho_data, :compute_matrix_ms, 100)
      DichoResolutionTimings.increment!(service_vrp.dicho_data, :compute_matrix_calls)
      DichoResolutionTimings.increment!(service_vrp.dicho_data, :end_stage_skipped_count, 3)
      OrtoolsTimings.add!(service_vrp.dicho_data, :total_ms, 200)
      OrtoolsTimings.increment!(service_vrp.dicho_data, :calls)

      DichoResolutionTimings.increment!(service_vrp.dicho_data, :end_stage_insert_attempts, 5)
      DichoResolutionTimings.increment!(service_vrp.dicho_data, :end_stage_insert_successes, 2)
      DichoResolutionTimings.increment!(service_vrp.dicho_data, :end_stage_insert_rejected, 2)
      DichoResolutionTimings.increment!(service_vrp.dicho_data, :end_stage_insert_no_result, 1)
      DichoResolutionTimings.increment!(service_vrp.dicho_data, :end_stage_services_inserted, 3)

      before = DichoResolutionTimings.end_stage_counter_snapshot(service_vrp.dicho_data)
      DichoResolutionTimings.increment!(service_vrp.dicho_data, :end_stage_insert_attempts)
      after = DichoResolutionTimings.end_stage_counter_snapshot(service_vrp.dicho_data)
      delta = DichoResolutionTimings.end_stage_counter_delta(before, after)
      assert_equal 1, delta[:end_stage_insert_attempts]

      stored = DichoResolutionTimings.for_dicho_data(service_vrp.dicho_data)
      assert_equal 100, stored[:compute_matrix_ms]
      assert_equal 1, stored[:compute_matrix_calls]
      assert_equal 6, stored[:end_stage_insert_attempts]
      assert_equal 2, stored[:end_stage_insert_successes]
      assert_equal 2, stored[:end_stage_insert_rejected]
      assert_equal 1, stored[:end_stage_insert_no_result]
      assert_equal 3, stored[:end_stage_services_inserted]
      assert_equal 3, stored[:end_stage_skipped_count]
    end
  end
end
