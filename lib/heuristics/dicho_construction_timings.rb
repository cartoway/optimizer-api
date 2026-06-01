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
# Accumulates monotonic timings for dichotomous sub-problem construction.

module Interpreters
  module DichoConstructionTimings
    SUM_KEYS = %i[
      initialize_split_data_ms
      initialize_split_kmeans_ms
      initialize_representative_vrp_ms
      split_kmeans_ms
      create_sub_vrp_ms
      create_sub_vrp_config_copy_ms
      build_partial_ms
      build_partial_delete_all_ms
      build_partial_vrp_create_ms
      build_partial_matrix_ms
      build_partial_context_ms
      exclusion_costs_ms
      define_process_reinsert_ms
    ].freeze

    TOTAL_KEYS = %i[
      initialize_split_data_ms
      split_kmeans_ms
      create_sub_vrp_ms
      build_partial_ms
      exclusion_costs_ms
      define_process_reinsert_ms
    ].freeze

    COUNTER_KEYS = %i[split_retries splits_count].freeze

    def self.ensure!(dicho_data)
      return unless dicho_data.is_a?(Hash)

      dicho_data[:construction_timings] ||= empty_hash
    end

    def self.empty_hash
      hash = SUM_KEYS.each_with_object({}) { |key, memo| memo[key] = 0.0 }
      COUNTER_KEYS.each { |key| hash[key] = 0 }
      hash
    end

    def self.add!(dicho_data, key, ms)
      return unless dicho_data.is_a?(Hash)

      ensure!(dicho_data)
      dicho_data[:construction_timings][key] += ms
    end

    def self.increment!(dicho_data, key, count = 1)
      return unless dicho_data.is_a?(Hash)

      ensure!(dicho_data)
      dicho_data[:construction_timings][key] += count
    end

    def self.measure(dicho_data, key)
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = yield
      add!(dicho_data, key, (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000)
      result
    end

    def self.total_ms(timings)
      TOTAL_KEYS.sum { |key| timings[key].to_f }
    end

    def self.log_summary!(service_vrp)
      dicho_data = service_vrp.dicho_data
      timings = dicho_data[:construction_timings]
      return unless timings

      log 'dicho construction timings (ms): ' \
          "total=#{total_ms(timings).round(1)} " \
          "init=#{timings[:initialize_split_data_ms].round(1)} " \
          "(kmeans=#{timings[:initialize_split_kmeans_ms].round(1)} " \
          "repr=#{timings[:initialize_representative_vrp_ms].round(1)}) " \
          "split_kmeans=#{timings[:split_kmeans_ms].round(1)} " \
          "create_sub_vrp=#{timings[:create_sub_vrp_ms].round(1)} " \
          "build_partial=#{timings[:build_partial_ms].round(1)} " \
          "(assembly=#{timings[:build_partial_vrp_create_ms].round(1)} " \
          "matrix=#{timings[:build_partial_matrix_ms].round(1)} " \
          "context=#{timings[:build_partial_context_ms].round(1)}) " \
          "exclusion=#{timings[:exclusion_costs_ms].round(1)} " \
          "define_reinsert=#{timings[:define_process_reinsert_ms].round(1)} " \
          "splits=#{timings[:splits_count]} retries=#{timings[:split_retries]}",
          level: :info
    end
  end
end
