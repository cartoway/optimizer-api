# Copyright © Cartoway, 2026
#
# Accumulates monotonic wall-clock timings for dicho resolution phases outside
# construction (split/build) and OR-Tools wrapper detail.

require './lib/heuristics/dicho_end_stage_solver'

module Interpreters
  module DichoResolutionTimings
    SUM_KEYS = %i[
      compute_matrix_ms
      heuristic_selection_ms
      heuristic_selection_solver_ms
      end_stage_insert_ms
      dicho_postprocess_ms
    ].freeze

    COUNTER_KEYS = %i[
      compute_matrix_calls
      heuristic_selection_calls
      end_stage_insert_calls
      end_stage_skipped_count
      end_stage_insert_attempts
      end_stage_insert_successes
      end_stage_insert_rejected
      end_stage_insert_no_result
      end_stage_services_inserted
      dicho_postprocess_calls
    ].freeze

    END_STAGE_COUNTER_KEYS = %i[
      end_stage_insert_attempts
      end_stage_insert_successes
      end_stage_insert_rejected
      end_stage_insert_no_result
      end_stage_services_inserted
    ].freeze

    def self.end_stage_counter_snapshot(dicho_data)
      stored = for_dicho_data(dicho_data) || {}
      END_STAGE_COUNTER_KEYS.index_with { |key| stored[key].to_i }
    end

    def self.end_stage_counter_delta(before, after)
      END_STAGE_COUNTER_KEYS.index_with { |key| after[key].to_i - before[key].to_i }
    end

    def self.ensure!(dicho_data)
      return unless dicho_data.is_a?(Hash)

      dicho_data[:resolution_timings] ||= empty_hash
    end

    def self.empty_hash
      hash = SUM_KEYS.each_with_object({}) { |key, memo| memo[key] = 0.0 }
      COUNTER_KEYS.each { |key| hash[key] = 0 }
      hash
    end

    def self.for_dicho_data(dicho_data)
      return unless dicho_data.is_a?(Hash)

      ensure!(dicho_data)
      dicho_data[:resolution_timings]
    end

    def self.add!(dicho_data, key, ms)
      return unless dicho_data.is_a?(Hash)

      ensure!(dicho_data)
      dicho_data[:resolution_timings][key] += ms
    end

    def self.increment!(dicho_data, key, count = 1)
      return unless dicho_data.is_a?(Hash)

      ensure!(dicho_data)
      dicho_data[:resolution_timings][key] += count
    end

    def self.measure(dicho_data, key)
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = yield
      add!(dicho_data, key, (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000)
      result
    end

    def self.log_summary!(service_vrp, construction_ms: nil, ortools_timings: nil)
      dicho_data = service_vrp&.dicho_data
      stored = for_dicho_data(dicho_data)
      return unless stored

      construction_ms ||= Interpreters::DichoConstructionTimings.total_ms(
        dicho_data[:construction_timings] || {}
      )
      ortools_timings ||= Interpreters::OrtoolsTimings.for_dicho_data(dicho_data)

      postprocess_ms = stored[:dicho_postprocess_ms].to_f
      end_stage_ms = stored[:end_stage_insert_ms].to_f
      postprocess_ruby_ms = [postprocess_ms - end_stage_ms, 0].max
      ortools_wall_ms = (ortools_timings&.dig(:total_ms) || 0).to_f
      dicho_data = service_vrp.dicho_data
      end_stage_budget_initial = dicho_data.is_a?(Hash) ? dicho_data[:end_stage_time_budget_initial_ms] : nil
      end_stage_budget_remaining = dicho_data.is_a?(Hash) ? dicho_data[:end_stage_time_budget_ms] : nil
      end_stage_budget_log =
        if end_stage_budget_initial
          " end_stage_budget=#{end_stage_budget_remaining.to_f.round(1)}/#{end_stage_budget_initial.to_f.round(1)}"
        else
          ''
        end
      deadline_remaining = dicho_data.is_a?(Hash) ? DichoEndStageSolver.resolution_deadline_remaining_ms(service_vrp) : nil
      deadline_log =
        if deadline_remaining
          " deadline_remaining=#{deadline_remaining.round(1)}"
        else
          ''
        end

      # postprocess/end_stage wall time includes Orchestration.solve waits already counted in ortools_wall.
      accounted_low = construction_ms.to_f + stored[:compute_matrix_ms].to_f +
                      stored[:heuristic_selection_ms].to_f + ortools_wall_ms
      accounted_high = accounted_low + postprocess_ruby_ms

      log 'dicho resolution timings (ms): ' \
          "accounted_ortools=#{accounted_low.round(1)} " \
          "accounted_upper=#{accounted_high.round(1)} " \
          "matrix=#{stored[:compute_matrix_ms].round(1)}(#{stored[:compute_matrix_calls]}) " \
          "heuristic_sel=#{stored[:heuristic_selection_ms].round(1)} " \
          "(solver=#{stored[:heuristic_selection_solver_ms].round(1)} " \
          "calls=#{stored[:heuristic_selection_calls]}) " \
          "end_stage=#{end_stage_ms.round(1)}(#{stored[:end_stage_insert_calls]}) " \
          "insert_attempts=#{stored[:end_stage_insert_attempts]} " \
          "insert_successes=#{stored[:end_stage_insert_successes]} " \
          "insert_rejected=#{stored[:end_stage_insert_rejected]} " \
          "insert_no_result=#{stored[:end_stage_insert_no_result]} " \
          "inserted=#{stored[:end_stage_services_inserted]} " \
          "skipped=#{stored[:end_stage_skipped_count]} " \
          "postprocess_ruby=#{postprocess_ruby_ms.round(1)} " \
          "postprocess_total=#{postprocess_ms.round(1)}(#{stored[:dicho_postprocess_calls]}) " \
          "construction=#{construction_ms.round(1)} " \
          "ortools_wall=#{ortools_wall_ms.round(1)}#{end_stage_budget_log}#{deadline_log}",
          level: :info
      log 'dicho resolution note: end_stage/postprocess overlap ortools_wall (solve waits counted in both); ' \
          'accounted_ortools=construction+matrix+heuristic+ortools; ' \
          'accounted_upper adds postprocess Ruby only (excludes end_stage to avoid ortools double-count); ' \
          'time budgets use wall clock (not solver-reported elapsed)',
          level: :info
    end
  end
end
