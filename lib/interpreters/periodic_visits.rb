# Copyright © Mapotempo, 2016
#
# This file is part of Mapotempo.
#
# Mapotempo is free software. You can redistribute it and/or
# modify since you respect the terms of the GNU Affero General
# Public License as published by the Free Software Foundation,
# either version 3 of the License, or (at your option) any later version.
#
# Mapotempo is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY
# or FITNESS FOR A PARTICULAR PURPOSE.  See the Licenses for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with Mapotempo. If not, see:
# <http://www.gnu.org/licenses/agpl.html>
#

module Interpreters
  class PeriodicVisits

    def self.expand(vrp)
      frequencies = []
      if vrp.relations.size == 0
        vrp.relations = []
      end
      services_unavailable_indices = []
      if vrp.schedule_range_indices || vrp.schedule_range_date
        epoch = Date.new(1970,1,1)
        real_schedule_start = vrp.schedule_range_indices ? vrp.schedule_range_indices[:start] : (vrp.schedule_range_date[:start].to_date - epoch).to_i
        real_schedule_end = vrp.schedule_range_indices ? vrp.schedule_range_indices[:end] : (vrp.schedule_range_date[:end].to_date - epoch).to_i
        shift = vrp.schedule_range_indices ? real_schedule_start : vrp.schedule_range_date[:start].to_date.cwday - 1
        schedule_end = real_schedule_end - real_schedule_start
        schedule_start = 0
        have_services_day_index = vrp.services.none? { |service| service.activity.timewindows.none? || service.activity.timewindows.none? { |timewindow| timewindow[:day_index] } }
        have_vehicles_day_index = vrp.vehicles.none? { |vehicle| vehicle.sequence_timewindows.none? || vehicle.sequence_timewindows.none? { |timewindow| timewindow[:day_index] } }

        unavailable_indices = if vrp.schedule_unavailable_indices
          vrp.schedule_unavailable_indices.collect { |unavailable_index|
            unavailable_index if unavailable_index >= schedule_start && unavailable_index <= schedule_end
          }.compact
        elsif vrp.schedule_unavailable_date
          vrp.schedule_unavailable_date.collect{ |date|
            (date - epoch).to_i - real_schedule_start if (date - epoch).to_i >= real_schedule_start
          }.compact
        end

        new_relations = vrp.relations.collect{ |relation|
          first_service = vrp.services.find{ |service| service.id == relation.linked_ids.first }
          relation_linked_ids = relation.linked_ids.select{ |mission_id|
            vrp.services.one? { |service| service.id == mission_id }
          }
          if first_service && first_service.visits_number && relation_linked_ids.all?{ |service_id|
              current_service = vrp.services.find{ |service| service.id == service_id }.visits_number == first_service.visits_number
            }
            (1..(first_service.visits_number || 1)).collect{ |relation_index|
              new_relation = Marshal::load(Marshal.dump(relation))
              new_relation.linked_ids = relation_linked_ids.collect{ |service_id| "#{service_id}_#{relation_index}/#{first_service.visits_number || 1}"}
              new_relation
            }
          end
        }.compact.flatten
        vrp.relations = new_relations

        new_services = vrp.services.collect{ |service|
          if service.unavailable_visit_day_date
            service.unavailable_visit_day_indices = service.unavailable_visit_day_date.collect{ |unavailable_date|
              (unavailable_date.to_date - epoch).to_i - real_schedule_start if (unavailable_date.to_date - epoch).to_i >= real_schedule_start
            }.compact
            if unavailable_indices
              service.unavailable_visit_day_indices += unavailable_indices.collect { |unavailable_index|
                unavailable_index if unavailable_index >= schedule_start && unavailable_index <= schedule_end
              }.compact
              service.unavailable_visit_day_indices.uniq
            end
          end

          if service.visits_number
            if service.minimum_lapse && service.visits_number > 1
              vrp.relations << Models::Relation.new(:type => "minimum_day_lapse",
              :linked_ids => (1..service.visits_number).collect{ |index| "#{service.id}_#{index}/#{service.visits_number}"},
              :lapse => service.minimum_lapse)
            end
            if service.maximum_lapse && service.visits_number > 1
              vrp.relations << Models::Relation.new(:type => "maximum_day_lapse",
                :linked_ids => (1..service.visits_number).collect{ |index| "#{service.id}_#{index}/#{service.visits_number}"},
                :lapse => service.maximum_lapse)
            end
            frequencies << service.visits_number
            visit_period = (schedule_end + 1).to_f/service.visits_number
            timewindows_iterations = (visit_period /(6 || 1)).ceil
            ## Create as much service as needed
            (0..service.visits_number-1).collect{ |visit_index|
              new_service = nil
              if !service.unavailable_visit_indices || service.unavailable_visit_indices.none?{ |unavailable_index| unavailable_index == visit_index }
                new_service = Marshal::load(Marshal.dump(service))
                new_service.id = "#{new_service.id}_#{visit_index+1}/#{new_service.visits_number}"
                new_service.activity.timewindows = if !service.activity.timewindows.empty?
                  new_timewindows = service.activity.timewindows.collect{ |timewindow|
                    if timewindow.day_index
                      {
                        id: ("#{timewindow[:id]} #{timewindow.day_index}" if timewindow[:id] && !timewindow[:id].nil?),
                        start: timewindow[:start] + timewindow.day_index * 86400,
                        end: timewindow[:end] + timewindow.day_index * 86400
                      }.delete_if { |k, v| !v }
                    elsif have_services_day_index || have_vehicles_day_index
                      (0..[6, schedule_end].min).collect{ |day_index|
                        {
                          id: ("#{timewindow[:id]} #{day_index}" if timewindow[:id] && !timewindow[:id].nil?),
                          start: timewindow[:start] + (day_index).to_i * 86400,
                          end: timewindow[:end] + (day_index).to_i * 86400
                        }.delete_if { |k, v| !v }
                      }
                    else
                      {
                        id: (timewindow[:id] if timewindow[:id] && !timewindow[:id].nil?),
                        start: timewindow[:start],
                        end: timewindow[:end]
                      }.delete_if { |k, v| !v }
                    end
                  }.flatten.sort_by{ |tw| tw[:start] }.compact.uniq
                  if new_timewindows.size > 0
                    new_timewindows
                  end
                end
                if !service.minimum_lapse && !service.maximum_lapse
                  new_service.skills += ["#{visit_index+1}_f_#{service.visits_number}"]
                end
                  new_service.skills += service.unavailable_visit_day_indices.collect{ |day_index|
                    services_unavailable_indices << day_index
                    "not_#{day_index}"
                  } if service.unavailable_visit_day_indices
                new_service
              else
                nil
              end
              new_service
            }.compact
          else
            service
          end
        }.flatten
        vrp.services = new_services

        services_unavailable_indices.uniq!
        frequencies.uniq!

        new_vehicles = vrp.vehicles.collect { |vehicle|
          if vehicle.unavailable_work_date
            vehicle.unavailable_work_day_indices = vehicle.unavailable_work_date.collect{ |unavailable_date|
              (unavailable_date.to_date - epoch).to_i - real_schedule_start if (unavailable_date.to_date - epoch).to_i >= real_schedule_start
            }.compact
          end
          if unavailable_indices
            vehicle.unavailable_work_day_indices += unavailable_indices.collect { |unavailable_index|
              unavailable_index
            }
            vehicle.unavailable_work_day_indices.uniq!
          end

          if vehicle.sequence_timewindows && !vehicle.sequence_timewindows.empty?
            new_periodic_vehicle = (schedule_start..schedule_end).collect{ |vehicle_day_index|
              if !vehicle.unavailable_work_day_indices || vehicle.unavailable_work_day_indices.none?{ |index| index == vehicle_day_index}
                associated_timewindow = vehicle.sequence_timewindows.find{ |timewindow| !timewindow[:day_index] || timewindow[:day_index] == (vehicle_day_index + shift) % 7 }
                if associated_timewindow
                  new_vehicle = Marshal::load(Marshal.dump(vehicle))
                  new_vehicle.id = "#{vehicle.id}_#{vehicle_day_index}"
                  new_vehicle.timewindow = {
                    id: ("#{associated_timewindow[:id]} #{(vehicle_day_index + shift) % 7}" if associated_timewindow[:id] && !associated_timewindow[:id].nil?),
                    start: (((vehicle_day_index + shift) % 7 )* 86400 + associated_timewindow[:start]),
                    end: (((vehicle_day_index + shift) % 7 )* 86400 + associated_timewindow[:end])
                  }.delete_if { |k, v| !v }
                  new_vehicle.global_day_index = vehicle_day_index
                  new_vehicle.sequence_timewindows = nil
                  associated_rests = vehicle.rests.select{ |rest| rest.timewindows.any?{ |timewindow| timewindow[:day_index] == (vehicle_day_index + shift) % 7 } }
                  new_vehicle.rests = associated_rests.collect{ |rest|
                    new_rest = Marshal::load(Marshal.dump(rest))
                    new_rest_timewindows = new_rest.timewindows.collect{ |timewindow|
                      if timewindow[:day_index] == (vehicle_day_index + shift) % 7
                        {
                          id: ("timewindow[:id] #{(vehicle_day_index + shift) % 7}" if timewindow[:id] && !timewindow[:id].nil?),
                          start: (((vehicle_day_index + shift) % 7 ) * 86400 + timewindow[:start]),
                          end: (((vehicle_day_index + shift) % 7 ) * 86400 + timewindow[:end])
                        }.delete_if { |k, v| !v }
                      end
                    }.compact
                    if new_rest_timewindows.size > 0
                      new_rest.timewindows = new_rest_timewindows
                      new_rest[:id] = "#{new_rest[:id]}_#{vehicle_day_index}"
                      new_rest
                    end
                  }
                  if new_vehicle.skills.empty?
                    new_vehicle.skills = [frequencies.collect { |frequency| "#{(vehicle_day_index * frequency / (schedule_end + 1)).to_i + 1}_f_#{frequency}" } + services_unavailable_indices.collect { |index|
                      if index != vehicle_day_index
                        "not_#{index}"
                      end
                    }.compact]
                  else
                    new_vehicle.skills.each{ |alternative_skill|
                      alternative_skill += frequencies.collect { |frequency| "#{(vehicle_day_index * frequency / (schedule_end + 1)).to_i + 1}_f_#{frequency}" } + services_unavailable_indices.collect { |index|
                        if index != vehicle_day_index
                          "not_#{index}"
                        end
                      }.compact
                    }
                  end
                  vrp.rests += new_vehicle.rests
                  new_vehicle
                else
                  nil
                end
              end
            }.compact
            vehicle.rests.each{ |rest|
              vrp.rests.delete(rest)
            }
            new_periodic_vehicle
          elsif !have_services_day_index
            new_periodic_vehicle = (schedule_start..schedule_end).collect{ |vehicle_day_index|
              new_vehicle = Marshal::load(Marshal.dump(vehicle))
              new_vehicle.id = "#{vehicle.id}_#{vehicle_day_index}"
              new_vehicle.global_day_index = vehicle_day_index
              if new_vehicle.skills.empty?
                new_vehicle.skills = [frequencies.collect { |frequency| "#{(vehicle_day_index * frequency / (schedule_end + 1)).to_i + 1}_f_#{frequency}" } + services_unavailable_indices.collect { |index|
                  if index != vehicle_day_index
                    "not_#{index}"
                  end
                }.compact]
              else
                new_vehicle.skills.each{ |alternative_skill|
                  alternative_skill += frequencies.collect { |frequency| "#{(vehicle_day_index * frequency / (schedule_end + 1)).to_i + 1}_f_#{frequency}" } + services_unavailable_indices.collect { |index|
                    if index != vehicle_day_index
                      "not_#{index}"
                    end
                  }.compact
                }
              end
              new_vehicle
            }
            new_periodic_vehicle
          else
            vehicle
          end
        }.flatten
        vrp.vehicles = new_vehicles.sort{ |a, b| a.global_day_index && b.global_day_index && a.global_day_index != b.global_day_index ? a.global_day_index <=> b.global_day_index : a.id <=> b.id }
      end
      vrp
    end

  end
end
