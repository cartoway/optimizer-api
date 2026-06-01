# Copyright © Cartoway, 2026
#
# This file is part of Cartoway.
#
# Cartoway is free software. You can redistribute it and/or
# modify since you respect the terms of the GNU Affero General
# Public License as published by the Free Software Foundation,
# either version 3 of the License, or (at your option) any later version.
#
# Cartoway is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY
# or FITNESS FOR A PARTICULAR PURPOSE.  See the Licenses for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with Cartoway. If not, see:
# <http://www.gnu.org/licenses/agpl.html>
#
# Accumulates monotonic wall-clock timings for OR-Tools wrapper phases.

module Interpreters
  module OrtoolsTimings
    SUM_KEYS = %i[
      build_problem_ms
      prepare_ms
      subprocess_ms
      parse_output_ms
      solver_reported_ms
      total_ms
    ].freeze

    COUNTER_KEYS = %i[calls heuristic_selection_calls].freeze

    def self.ruby_overhead_ms(stored)
      stored[:build_problem_ms] + stored[:prepare_ms] + stored[:parse_output_ms]
    end

    def self.ensure!(dicho_data)
      return unless dicho_data.is_a?(Hash)

      dicho_data[:ortools_timings] ||= empty_hash
    end

    def self.empty_hash
      hash = SUM_KEYS.each_with_object({}) { |key, memo| memo[key] = 0.0 }
      COUNTER_KEYS.each { |key| hash[key] = 0 }
      hash
    end

    def self.for_dicho_data(dicho_data)
      return unless dicho_data.is_a?(Hash)

      ensure!(dicho_data)
      dicho_data[:ortools_timings]
    end

    def self.add!(dicho_data, key, ms)
      return unless dicho_data.is_a?(Hash)

      ensure!(dicho_data)
      dicho_data[:ortools_timings][key] += ms
    end

    def self.increment!(dicho_data, key, count = 1)
      return unless dicho_data.is_a?(Hash)

      ensure!(dicho_data)
      dicho_data[:ortools_timings][key] += count
    end

    def self.record_call!(dicho_data, context: nil)
      increment!(dicho_data, :calls)
      increment!(dicho_data, :heuristic_selection_calls) if context == :heuristic_selection
    end

    def self.measure(dicho_data, key)
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = yield
      add!(dicho_data, key, (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000)
      result
    end

    def self.dicho_data_target(service_vrp)
      dicho_data = service_vrp&.dicho_data
      return unless dicho_data.is_a?(Hash)

      ensure!(dicho_data)
      dicho_data
    end

    def self.log_summary!(service_vrp)
      dicho_data = service_vrp&.dicho_data
      stored = for_dicho_data(dicho_data)
      return unless stored && stored[:calls].positive?

      ruby_ms = ruby_overhead_ms(stored)
      log 'dicho ortools timings (ms): ' \
          "wall_total=#{stored[:total_ms].round(1)} " \
          "ruby=#{ruby_ms.round(1)} " \
          "(build=#{stored[:build_problem_ms].round(1)} " \
          "prepare=#{stored[:prepare_ms].round(1)} " \
          "parse=#{stored[:parse_output_ms].round(1)}) " \
          "subprocess_wall=#{stored[:subprocess_ms].round(1)} " \
          "solver_reported=#{stored[:solver_reported_ms].round(1)} " \
          "calls=#{stored[:calls]} " \
          "heuristic_calls=#{stored[:heuristic_selection_calls]}",
          level: :info
      log 'dicho ortools note: parse is included in subprocess_wall; ' \
          'solver_reported is OR-Tools internal time (not Ruby wall clock)',
          level: :info
    end
  end
end
