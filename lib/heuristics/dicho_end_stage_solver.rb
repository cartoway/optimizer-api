# Copyright © Cartoway, 2026
#
# end_stage guards, slicing, and insertion counters (solve via Orchestration.solve).

require './lib/heuristics/dicho_resolution_timings'

module Interpreters
  module DichoEndStageSolver
    MIN_SOLVE_DURATION_MS = 150

    def self.resolution_deadline_remaining_ms(service_vrp)
      dicho_data = service_vrp.dicho_data
      deadline = dicho_data.is_a?(Hash) ? dicho_data[:resolution_deadline_monotonic] : nil
      return nil unless deadline

      [(deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)) * 1000, 0].max
    end

    def self.resolution_deadline_reached?(service_vrp)
      remaining = resolution_deadline_remaining_ms(service_vrp)
      !remaining.nil? && remaining <= MIN_SOLVE_DURATION_MS
    end

    def self.time_share(resolution)
      share = resolution.dicho_end_stage_time_share
      return nil if share.nil?

      share = share.to_f
      return nil if share <= 0

      [share, 1.0].min
    end

    def self.dedicated_time_budget?(service_vrp)
      service_vrp.dicho_data.is_a?(Hash) && service_vrp.dicho_data.key?(:end_stage_time_budget_ms)
    end

    def self.remaining_end_stage_time_budget(service_vrp)
      service_vrp.dicho_data[:end_stage_time_budget_ms].to_f
    end

    # Split total duration at dicho root: main tree vs end_stage pool (shared across all levels).
    def self.reserve_time_budget!(service_vrp)
      return unless service_vrp.dicho_level.to_i.zero?
      return unless service_vrp.dicho_data.is_a?(Hash)
      return if service_vrp.dicho_data.key?(:end_stage_time_budget_ms)

      resolution = service_vrp.vrp.configuration.resolution
      share = time_share(resolution)
      return unless share && resolution.dicho_end_stage_enabled

      total = service_vrp.resolution_time_budget_ms
      return unless total&.positive?

      end_stage_ms = (total * share).floor
      main_ms = total - end_stage_ms
      return if main_ms <= MIN_SOLVE_DURATION_MS || end_stage_ms <= MIN_SOLVE_DURATION_MS

      dicho_data = service_vrp.dicho_data
      dicho_data[:end_stage_time_budget_ms] = end_stage_ms
      dicho_data[:end_stage_time_budget_initial_ms] = end_stage_ms
      service_vrp.resolution_time_budget_ms = main_ms
      log "dicho - end_stage time budget reserved: #{end_stage_ms.round}ms " \
          "(#{(share * 100).round(1)}% of #{total.round}ms), main dicho budget: #{main_ms.round}ms",
          level: :info
    end

    def self.end_stage_active?(service_vrp, solution)
      return false if solution.unassigned_stops.empty?

      resolution = service_vrp.vrp.configuration.resolution
      unless resolution.dicho_end_stage_enabled
        record_skip!(service_vrp, :disabled)
        return false
      end

      if resolution_deadline_reached?(service_vrp)
        record_skip!(service_vrp, :deadline)
        return false
      end

      if dedicated_time_budget?(service_vrp) &&
         remaining_end_stage_time_budget(service_vrp) <= MIN_SOLVE_DURATION_MS
        record_skip!(service_vrp, :time_budget)
        return false
      end

      true
    end

    def self.record_skip!(service_vrp, reason = nil)
      dicho_data = service_vrp.dicho_data
      return unless dicho_data.is_a?(Hash)

      DichoResolutionTimings.increment!(dicho_data, :end_stage_skipped_count)
      log "dicho end_stage skipped level(#{service_vrp.dicho_level}): #{reason || 'guards'}",
          level: :debug
    end

    def self.cap_end_stage_solve_duration!(service_vrp, solve_duration_ms)
      return solve_duration_ms unless dedicated_time_budget?(service_vrp)

      limits = [remaining_end_stage_time_budget(service_vrp).round]
      deadline_ms = resolution_deadline_remaining_ms(service_vrp)
      limits << deadline_ms.round if deadline_ms
      capped = [solve_duration_ms, *limits].min
      capped <= MIN_SOLVE_DURATION_MS ? nil : capped
    end

    def self.end_stage_wall_consumed_ms(dicho_data)
      return 0 unless dicho_data.is_a?(Hash)

      dicho_data[:end_stage_wall_consumed_ms].to_f
    end

    def self.consume_end_stage_elapsed!(service_vrp, wall_ms)
      return unless dedicated_time_budget?(service_vrp)

      wall_ms = wall_ms.to_f
      dicho_data = service_vrp.dicho_data
      dicho_data[:end_stage_time_budget_ms] =
        [dicho_data[:end_stage_time_budget_ms].to_f - wall_ms, 0].max
      dicho_data[:end_stage_wall_consumed_ms] = end_stage_wall_consumed_ms(dicho_data) + wall_ms
    end

    def self.record_insert_attempt!(dicho_data)
      return unless dicho_data.is_a?(Hash)

      DichoResolutionTimings.increment!(dicho_data, :end_stage_insert_attempts)
    end

    def self.record_insert_success!(dicho_data)
      return unless dicho_data.is_a?(Hash)

      DichoResolutionTimings.increment!(dicho_data, :end_stage_insert_successes)
    end

    def self.record_insert_rejected!(dicho_data)
      return unless dicho_data.is_a?(Hash)

      DichoResolutionTimings.increment!(dicho_data, :end_stage_insert_rejected)
    end

    def self.record_insert_no_result!(dicho_data)
      return unless dicho_data.is_a?(Hash)

      DichoResolutionTimings.increment!(dicho_data, :end_stage_insert_no_result)
    end

    def self.record_inserted!(dicho_data, count)
      return unless dicho_data.is_a?(Hash) && count.to_i.positive?

      DichoResolutionTimings.increment!(dicho_data, :end_stage_services_inserted, count.to_i)
    end
  end
end
