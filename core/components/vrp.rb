module Core
  module Components
    module Vrp
      def compute_independent_skills_sets(vrp, mission_skills, vehicle_skills)
        independent_skills = Array.new(mission_skills.size) { |i| [i] }

        correspondance_hash = vrp.vehicles.map{ |vehicle|
          [vehicle.id, vehicle_skills.index{ |skills| skills == vehicle.skills.flatten }]
        }.to_h

        # Build the compatibility table between service and vehicle skills
        # As reminder vehicle skills are defined as an OR condition
        # When the services skills are defined as an AND condition
        compatibility_table = mission_skills.map.with_index{ |_skills, _index| Array.new(vehicle_skills.size) { false } }
        mission_skills.each.with_index{ |m_skills, m_index|
          vehicle_skills.each.with_index{ |v_skills, v_index|
            compatibility_table[m_index][v_index] = true if (m_skills - v_skills).empty?
          }
        }

        vrp.relations.select{ |relation|
          Models::Relation::ON_VEHICLES_TYPES.include?(relation.type)
        }.each{ |relation|
          v_skills_indices = relation.linked_vehicle_ids.map{ |v_id| correspondance_hash[v_id] }
          mission_skill_indices = []
          # We check if there is at least one vehicle of the relation compatible with a mission skills set
          v_skills_indices.each{ |v_index|
            mission_skills.each_index.each{ |m_index|
              mission_skill_indices << m_index if compatibility_table[m_index][v_index]
            }
          }
          next if mission_skill_indices.empty?

          mission_skill_indices.uniq!

          # If at last one vehicle of the relation is compatible, then we propagate it,
          # as we want all the relation vehicles to belong to the same problem
          v_skills_indices.each{ |v_index|
            mission_skill_indices.each{ |m_index|
              compatibility_table[m_index][v_index] = true
            }
          }
        }

        mission_skills.size.times.each{ |a_line|
          ((a_line + 1)..mission_skills.size - 1).each{ |b_line|
            next if (compatibility_table[a_line].select.with_index{ |state, index|
              state & compatibility_table[b_line][index]
            }).empty?

            b_set = independent_skills.find{ |set| set.include?(b_line) && set.exclude?(a_line) }
            next if b_set.nil?

            # Skills indices are merged as they have at least a vehicle in common
            independent_skills.delete(b_set)
            set_index = independent_skills.index{ |set| set.include?(a_line) }
            independent_skills[set_index] += b_set
          }
        }
        # Independent skill sets : Original skills are retrieved
        independent_skills.map{ |index_set|
          index_set.collect{ |index| mission_skills[index] }
        }
      end

      def filtered_solver_priority(vrp, profile)
        allowed_solvers = profile[:services][:vrp]
        requested_solvers = vrp.configuration.resolution.solver_priority
        if requested_solvers.empty?
          allowed_solvers
        else
          requested_solvers.map(&:to_sym) & allowed_solvers
        end
      end
      module_function :compute_independent_skills_sets, :filtered_solver_priority
    end
  end
end
