# Copyright © Cartoway, 2026
#
# This file is part of Cartoway Optimizer.
#
# Cartoway Optimizer is free software. You can redistribute it and/or
# modify since you respect the terms of the GNU Affero General
# Public License as published by the Free Software Foundation,
# either version 3 of the License, or (at your option) any later version.
#
# You should have received a copy of the GNU Affero General Public License
# along with Cartoway Optimizer. If not, see:
# <http://www.gnu.org/licenses/agpl.html>
#

module Interpreters
  # Inflate travel/service by duration/lapse, then reinsert discrete pauses
  # after the visit (if the lapse is reached during service) or before travel
  # (if the drive would complete it, and the next stop still fits its timewindow).
  class RegulatoryRest
    UNREACHABLE = (2**31) - 1

    def self.applicable?(vrp)
      !vrp.nil? && !vrp.schedule? && lapse_rests(vrp).any?
    end

    def self.lapse_rests(vrp)
      vrp.vehicles.flat_map(&:rests).select{ |rest| lapse_rest?(rest) }.uniq
    end

    def self.lapse_rest?(rest)
      rest&.lapse.to_i.positive? && rest.duration.to_i.positive?
    end

    def self.solver_rests(vehicle)
      vehicle.rests.reject{ |rest| lapse_rest?(rest) }
    end

    def apply!(vrp)
      return false unless self.class.applicable?(vrp)
      return true if vrp[:regulatory_rest_snapshot]

      rests = self.class.lapse_rests(vrp)
      rates = rests.map{ |rest| rest.duration.to_f / rest.lapse }.uniq
      if rates.size > 1
        raise OptimizerWrapper::UnsupportedProblemError.new(
          'Regulatory rests must share the same duration/lapse ratio'
        )
      end

      rate = rates.first
      tour_start = vrp.vehicles.map{ |vehicle| vehicle.timewindow&.start }.compact.min || 0
      snapshot!(vrp)
      inflate_matrices!(vrp, rate)
      inflate_durations!(vrp, rate)
      delay_timewindow_starts!(vrp, rate, tour_start, rests.map(&:duration).min)
      strip_lapse_rests!(vrp)
      log "RegulatoryRest: inflate rate=#{rate.round(4)} tour_start=#{tour_start}", level: :info
      true
    end

    def rewind!(vrp)
      snapshot = vrp && vrp[:regulatory_rest_snapshot]
      return unless snapshot

      snapshot[:matrices].each{ |matrix, original_time|
        matrix.time = original_time.map(&:dup)
        matrix.clear_flatten_cache!
      }
      snapshot[:durations].each{ |activity, (duration, setup_duration)|
        activity.duration = duration
        activity.setup_duration = setup_duration if activity.respond_to?(:setup_duration=)
      }
      snapshot[:tw_starts].each{ |timewindow, tw_start| timewindow.start = tw_start }
      snapshot[:vehicle_rests].each{ |vehicle, rests| vehicle.rests = rests }
      vrp.rests = snapshot[:vrp_rests]
      vrp[:regulatory_rest_snapshot] = nil
    end

    def patch_solution!(vrp, solution)
      rewind!(vrp) if vrp[:regulatory_rest_snapshot]
      return unless solution

      rest_by_vehicle = vrp.vehicles.filter_map{ |vehicle|
        rest = vehicle.rests.find{ |candidate| self.class.lapse_rest?(candidate) }
        [vehicle.id, rest] if rest
      }.to_h
      return if rest_by_vehicle.empty?

      solution.routes.each{ |route|
        rest = rest_by_vehicle[route.vehicle&.id]
        next unless rest && route.stops.any?

        rebuild_route_with_pauses!(vrp, route, rest)
      }
    end

    private

    def snapshot!(vrp)
      durations = {}
      each_activity(vrp){ |activity|
        durations[activity] = [activity.duration, activity.respond_to?(:setup_duration) ? activity.setup_duration : 0]
      }

      tw_starts = {}
      each_activity(vrp){ |activity|
        activity.timewindows.each{ |timewindow| tw_starts[timewindow] = timewindow.start }
      }

      vrp[:regulatory_rest_snapshot] = {
        matrices: vrp.matrices.select(&:time).map{ |matrix| [matrix, matrix.time.map(&:dup)] }.to_h,
        durations: durations,
        tw_starts: tw_starts,
        vehicle_rests: vrp.vehicles.map{ |vehicle| [vehicle, vehicle.rests.dup] }.to_h,
        vrp_rests: vrp.rests.dup,
      }
    end

    def inflate_matrices!(vrp, rate)
      vrp.matrices.each{ |matrix|
        next unless matrix.time

        matrix.time.each_with_index{ |row, i|
          row.each_with_index{ |value, j|
            next if i == j || value.nil? || value >= UNREACHABLE

            row[j] = inflate(value, rate)
          }
        }
        matrix.clear_flatten_cache!
      }
    end

    def inflate_durations!(vrp, rate)
      each_activity(vrp){ |activity|
        activity.duration = inflate(activity.duration, rate)
        next unless activity.respond_to?(:setup_duration) && activity.setup_duration.to_i.positive?

        activity.setup_duration = inflate(activity.setup_duration, rate)
      }
    end

    def strip_lapse_rests!(vrp)
      vrp.vehicles.each{ |vehicle| vehicle.rests = self.class.solver_rests(vehicle) }
      vrp.rests = vrp.rests.reject{ |rest| self.class.lapse_rest?(rest) }
    end

    def each_activity(vrp, &block)
      vrp.services.each{ |service|
        [service.activity, *service.activities.to_a].compact.each(&block)
      }
      vrp.reload_depots.each(&block)
    end

    def inflate(value, rate)
      (value.to_f * (1 + rate)).ceil
    end

    def delay_timewindow_starts!(vrp, rate, tour_start, cap)
      each_activity(vrp){ |activity|
        activity.timewindows.each{ |timewindow|
          next if timewindow.start.nil?

          delayed = timewindow.start + start_delay(timewindow.start, tour_start, rate, cap)
          next if timewindow.end && delayed >= timewindow.end

          timewindow.start = delayed
        }
      }
    end

    def start_delay(tw_start, tour_start, rate, cap)
      extra = (tw_start - tour_start) * rate
      extra = 0 if extra.negative?
      [extra.ceil, cap].min
    end

    def rebuild_route_with_pauses!(vrp, route, rest)
      matrix = vrp.matrices.find{ |mat| mat.id == route.vehicle.matrix_id }
      vehicle = route.vehicle
      lapse = rest.lapse
      pause_duration = rest.duration
      work = 0
      pause_index = 0
      previous_index = nil
      previous_point_id = nil
      clock = route.info.start_time || vehicle.timewindow&.start.to_i
      new_stops = []

      route.stops.reject{ |stop| stop.type == :rest }.each{ |stop|
        restore_stop_durations!(stop)
        current_index = stop.activity.point&.matrix_index
        travel = travel_time(matrix, previous_index, current_index)
        setup = setup_time(stop, vehicle, previous_point_id)
        service = service_time(stop, vehicle)

        if work.positive? && work + travel >= lapse && pause_fits_before_stop?(stop, clock, travel, pause_duration)
          pause_index += 1
          new_stops << build_rest_stop(rest, pause_index, clock, pause_duration)
          clock += pause_duration
          work = 0
        end

        clock += travel
        waiting = waiting_time(stop, clock)
        clock += waiting
        begin_time = clock
        clock += setup + service

        stop.info.travel_time = travel
        stop.info.waiting_time = waiting
        stop.info.begin_time = begin_time
        stop.info.end_time = clock
        stop.info.departure_time = clock
        new_stops << stop

        work += travel + setup + service
        if work >= lapse
          pause_index += 1
          new_stops << build_rest_stop(rest, pause_index, clock, pause_duration)
          clock += pause_duration
          work = 0
        end

        previous_index = current_index if current_index
        previous_point_id = stop.activity.point_id if stop.activity.point_id
      }

      route.stops.replace(new_stops)
      route.info.end_time = clock if new_stops.any?
    end

    def travel_time(matrix, previous_index, current_index)
      return 0 unless matrix&.time && previous_index && current_index

      matrix.time[previous_index][current_index].to_i
    end

    def setup_time(stop, vehicle, previous_point_id)
      return 0 if stop.type == :depot || previous_point_id.nil?
      return 0 if stop.activity.point_id == previous_point_id

      activity = mission_activity(stop)
      activity ? activity.setup_duration_on(vehicle).to_i : 0
    end

    def service_time(stop, vehicle)
      return 0 if stop.type == :depot

      activity = mission_activity(stop)
      return stop.activity.duration.to_i unless activity

      activity.duration_on(vehicle).to_i
    end

    def waiting_time(stop, arrival)
      timewindows = mission_activity(stop)&.timewindows.to_a
      return 0 if timewindows.empty?

      earliest_start = timewindows.find{ |tw| (tw.end || 2**32) > arrival }&.start || 0
      [earliest_start - arrival, 0].max
    end

    def pause_fits_before_stop?(stop, clock, travel, pause_duration)
      begin_time = clock + pause_duration + travel
      begin_time += waiting_time(stop, begin_time)
      timewindows = mission_activity(stop)&.timewindows.to_a
      return true if timewindows.empty?

      timewindows.any?{ |tw|
        (tw.start.nil? || begin_time >= tw.start) && (tw.end.nil? || begin_time <= tw.end)
      }
    end

    def mission_activity(stop)
      mission = stop.mission
      return stop.activity unless mission
      return mission if mission.is_a?(Models::Activity) || mission.is_a?(Models::ReloadDepot)
      return mission.activity if mission.respond_to?(:activity) && mission.activity
      return mission.activities[stop.alternative.to_i] if mission.respond_to?(:activities) && mission.activities.any?

      stop.activity
    end

    def restore_stop_durations!(stop)
      activity = mission_activity(stop)
      return unless activity && stop.activity && activity != stop.activity

      stop.activity.duration = activity.duration
      return unless stop.activity.respond_to?(:setup_duration=) && activity.respond_to?(:setup_duration)

      stop.activity.setup_duration = activity.setup_duration
    end

    def build_rest_stop(rest, pause_index, begin_time, duration)
      rest_copy = Models::Rest.new(
        id: "#{rest.id}##{pause_index}",
        original_id: rest.original_id || rest.id,
        duration: duration
      )
      Models::Solution::Stop.new(
        rest_copy,
        info: Models::Solution::Stop::Info.new(
          begin_time: begin_time,
          end_time: begin_time + duration,
          departure_time: begin_time + duration,
          travel_time: 0
        )
      )
    end
  end
end
