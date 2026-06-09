# Copyright © Cartoway, 2026
#
# Per-dicho-level wall-clock timings for a full tree walk (shared via dicho_data).

module Interpreters
  module DichoLevelTimings
    SUM_KEYS = %i[
      node_total_ms
      matrix_ms
      exclusion_ms
      pre_split_solve_ms
      split_ms
      children_ms
      postprocess_ms
      end_stage_ms
      ortools_wall_ms
      ortools_ruby_ms
      ortools_solver_ms
    ].freeze

    COUNTER_KEYS = %i[ortools_calls splits_count].freeze

    LOG_COLUMNS = 'lvl srv veh node split children postprocess end_stage pre_solve matrix exclusion ' \
                  'ortools_wall ortools_ruby ortools_solver ort_calls splits'.freeze

    def self.ensure!(dicho_data)
      return unless dicho_data.is_a?(Hash)

      dicho_data[:level_timings] ||= {}
    end

    def self.empty_bucket
      hash = SUM_KEYS.each_with_object({}) { |key, memo| memo[key] = 0.0 }
      COUNTER_KEYS.each { |key| hash[key] = 0 }
      hash[:services] = nil
      hash[:vehicles] = nil
      hash
    end

    def self.bucket(dicho_data, level)
      ensure!(dicho_data)
      dicho_data[:level_timings][level] ||= empty_bucket
    end

    def self.record_context!(dicho_data, level, vrp)
      return unless dicho_data.is_a?(Hash) && !level.nil? && vrp

      b = bucket(dicho_data, level)
      b[:services] = vrp.services.size
      b[:vehicles] = vrp.vehicles.size
    end

    def self.add!(dicho_data, level, key, ms)
      return unless dicho_data.is_a?(Hash) && !level.nil?

      bucket(dicho_data, level)[key] += ms
    end

    def self.increment!(dicho_data, level, key, count = 1)
      return unless dicho_data.is_a?(Hash) && !level.nil?

      bucket(dicho_data, level)[key] += count
    end

    def self.measure(dicho_data, level, key)
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = yield
      add!(dicho_data, level, key, (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000)
      result
    end

    def self.record_ortools_call!(dicho_data, level, total_ms:, ruby_ms:, solver_ms:)
      return unless dicho_data.is_a?(Hash) && !level.nil?

      add!(dicho_data, level, :ortools_wall_ms, total_ms)
      add!(dicho_data, level, :ortools_ruby_ms, ruby_ms)
      add!(dicho_data, level, :ortools_solver_ms, solver_ms.to_f)
      increment!(dicho_data, level, :ortools_calls)
    end

    def self.log_summary!(service_vrp)
      dicho_data = service_vrp&.dicho_data
      ensure!(dicho_data)
      levels = dicho_data[:level_timings]
      return if levels.nil? || levels.empty?

      log "dicho level timings (ms): #{LOG_COLUMNS}", level: :info

      levels.sort.each do |level, bucket|
        log level_line('L', level, bucket), level: :info
      end

      totals = empty_bucket
      levels.each_value do |bucket|
        SUM_KEYS.each { |key| totals[key] += bucket[key].to_f }
        COUNTER_KEYS.each { |key| totals[key] += bucket[key].to_i }
      end
      global_ortools_calls = Interpreters::OrtoolsTimings.for_dicho_data(dicho_data)&.dig(:calls)
      totals[:ortools_calls] = global_ortools_calls if global_ortools_calls
      log level_line('T', 'OT', totals), level: :info
      log 'dicho level note: children=recursive define_process; node≈split+children+postprocess+pre_solve at this lvl; ' \
          'ortools_wall is cumulative per level (sum of solve() wall times); ' \
          'TOT node/children sums are nested (do not add levels); TOT ort_calls uses global ortools count',
          level: :info
    end

    def self.level_line(prefix, level, bucket)
      fields = [
        format('%<prefix>s%-3<level>s', prefix: prefix, level: level),
        format('%4s', bucket[:services] || '-'),
        format('%3s', bucket[:vehicles] || '-'),
        bucket[:node_total_ms].round(1),
        bucket[:split_ms].round(1),
        bucket[:children_ms].round(1),
        bucket[:postprocess_ms].round(1),
        bucket[:end_stage_ms].round(1),
        bucket[:pre_split_solve_ms].round(1),
        bucket[:matrix_ms].round(1),
        bucket[:exclusion_ms].round(1),
        bucket[:ortools_wall_ms].round(1),
        bucket[:ortools_ruby_ms].round(1),
        bucket[:ortools_solver_ms].round(1),
        bucket[:ortools_calls].to_i,
        bucket[:splits_count].to_i
      ]
      "dicho level timings: #{fields.join(' ')}"
    end

    private_class_method :level_line
  end
end
