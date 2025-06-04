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
# frozen_string_literal: true

require_all 'lib'
require_all 'util'
require_all 'core'

module OptimizerWrapper
  extend Core::Services::ClusteringService
  extend Core::Services::JobService
  extend Core::Strategies::Orchestration
  extend Core::Components::Solution
  extend Core::Components::Vehicle
  extend Core::Components::Vrp
  extend Core::Components::Zone

  def self.wrapper_vrp(api_key, profile, vrp, checksum, job_id = nil)
    inapplicable_services = []
    apply_zones(vrp)
    adjust_vehicles_duration(vrp)

    Filters.filter(vrp)

    vrp.configuration.resolution.repetition ||=
      if !vrp.configuration.preprocessing.partitions.empty? && vrp.periodic_heuristic?
        config[:solve][:repetition]
      else
        1
      end
    solver_priority = filtered_solver_priority(vrp, profile)

    services_vrps =
      split_independent_vrp(vrp).map{ |vrp_element|
        {
          service: solver_priority.find{ |s|
            inapplicable = config[:services][s].inapplicable_solve?(vrp_element)
            if inapplicable.empty?
              log "Select service #{s}"
              true
            else
              inapplicable_services << inapplicable
              log "Skip inapplicable #{s}: #{inapplicable.join(', ')}"
              false
            end
          },
          vrp: vrp_element,
          dicho_level: 0,
          dicho_denominators: [1],
          dicho_sides: [0]
        }
      }

    if services_vrps.any?{ |sv| !sv[:service] }
      raise UnsupportedProblemError.new('Cannot apply any of the solver services', inapplicable_services)
    elsif config[:solve][:synchronously] || (
            services_vrps.size == 1 &&
            !vrp.configuration.preprocessing.cluster_threshold &&
            config[:services][services_vrps[0][:service]].solve_synchronous?(vrp)
          )
      # The job seems easy enough to perform it with the server
      define_main_process(services_vrps, job_id)
    else
      # Delegate the job to a worker (expire is defined resque config)
      job_id = Job.enqueue_to(profile[:queue], Job, services_vrps: Base64.encode64(Marshal.dump(services_vrps)),
                                                    api_key: api_key,
                                                    checksum: checksum,
                                                    pids: [])
      JobList.add(api_key, job_id)
      job_id
    end
  end
end
