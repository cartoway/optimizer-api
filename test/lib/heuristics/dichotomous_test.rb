# Copyright © Mapotempo, 2018
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
require './test/test_helper'

class DichotomousTest < Minitest::Test
  if !ENV['SKIP_DICHO']
    def dicho_lat_lon_problem(service_count: 8, duration: 60_000)
      vrp = VRP.lat_lon
      vrp[:configuration][:resolution][:duration] = duration
      vrp[:services] = vrp[:services].first(service_count)
      vrp[:vehicles] = [vrp[:vehicles].first, vrp[:vehicles].first.dup]
      vrp[:vehicles].last[:id] = 'v_1'
      dicho_split_limits(TestHelper.create(vrp), duration: duration)
    end

    def dicho_split_limits(problem, duration: 60_000)
      problem.configuration.resolution.dicho_algorithm_vehicle_limit = 1
      problem.configuration.resolution.dicho_division_vehicle_limit = 1
      problem.configuration.resolution.dicho_algorithm_service_limit = 5
      problem.configuration.resolution.dicho_division_service_limit = 5
      problem.configuration.resolution.dicho_end_stage_enabled = false
      problem.vehicles.each{ |vehicle| vehicle.duration ||= duration }
      problem
    end

    def dicho_heuristic_service_vrp(problem)
      service_vrp = Models::ResolutionContext.new(
        vrp: problem,
        service: :ortools,
        dicho_level: 0,
        dicho_data: {}
      )
      Interpreters::Dichotomous.ensure_time_budget!(service_vrp)
      # Level-0 matrix/kmeans can exceed the resolution duration in CI; keep children reachable.
      service_vrp.dicho_data[:resolution_deadline_monotonic] =
        Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3600
      service_vrp
    end

    def with_fast_dicho_heuristic(problem)
      problem.stub(:compute_matrix, true) do
        problem.stub(:calculate_service_exclusion_costs, true) do
          yield dicho_heuristic_service_vrp(problem)
        end
      end
    end

    def with_stubbed_dicho_orchestration(recorded_durations: nil, elapsed: 100, &block)
      stub_solve =
        lambda{ |svrp, _job = nil, _block = nil|
          recorded_durations << svrp.vrp.configuration.resolution.duration.to_i if recorded_durations
          solution = svrp.vrp.empty_solution(:ortools, [], false)
          solution.elapsed = elapsed.respond_to?(:call) ? elapsed.call(svrp) : elapsed
          if Interpreters::Dichotomous.dicho_time_budget_active?(svrp)
            Interpreters::Dichotomous.consume_time_budget!(svrp, solution.elapsed)
          end
          solution
        }
      stub_define_process =
        lambda{ |svrp, job = nil, &progress_block|
          if svrp.dicho_level.to_i.positive?
            Interpreters::SeveralSolutions.ensure_dicho_first_solution_strategy!(svrp, progress_block)
          end
          stub_solve.call(svrp, job, progress_block)
        }
      Core::Strategies::Orchestration.stub(:define_process, stub_define_process) do
        Core::Strategies::Orchestration.stub(:solve, stub_solve, &block)
      end
    end

    def test_dichotomous_approach
      vrp = TestHelper.load_vrp(self)

      vrp.configuration.resolution.dicho_algorithm_service_limit = 457 # There are 458 services in the instance.

      vrp.configuration.resolution.minimum_duration = 60000 # instead of the original 480 and 540 seconds
      vrp.configuration.resolution.duration = 120000

      t1 = Time.now
      solution = OptimizerWrapper.wrapper_vrp('ortools', { services: { vrp: [:ortools] }}, vrp, nil)[0]
      t2 = Time.now

      active_route_size = solution.routes.count{ |route| route.count_services.positive? }

      # Check solution quality
      soln_quality_assert_message =
        "Too many unassigned services (#{solution.unassigned_stops.size}) for #{active_route_size} routes"
      if active_route_size > 12
        assert solution.unassigned_stops.size <= 13, soln_quality_assert_message
      elsif active_route_size == 12
        assert solution.unassigned_stops.size <= 23, soln_quality_assert_message
      elsif active_route_size == 11
        assert solution.unassigned_stops.size <= 33, soln_quality_assert_message
      else
        assert solution.unassigned_stops.size <= 43, soln_quality_assert_message
      end

      # Check elapsed time
      max_dur = vrp.configuration.resolution.duration / 1000.0
      min_dur = vrp.configuration.resolution.minimum_duration / 1000.0

      assert solution.elapsed / 1000 < max_dur * 1.05,
             "Time spent in optimization (#{solution.elapsed / 1000}) is greater than " \
             "the maximum duration asked (#{max_dur})."
      # Due to "no remaining jobs" in end_stage, it can be violated (randomly but very rarely).
      assert solution.elapsed / 1000 > min_dur * 0.99,
             "Time spent in optimization (#{solution.elapsed / 1000}) is less than " \
             "the minimum duration asked (#{min_dur})."
      # Due to API overhead, it can be violated (randomly but very rarely).
      # Since the optimisation time is short the relative overhead is big.
      assert t2 - t1 < max_dur * 2.5,
             "Time spend in the API (#{t2 - t1}) is too big compared to maximum " \
             "optimization duration asked (#{max_dur})."
    end

    def test_dichotomous_condition_limits
      # Currently dicho limit is set to 500 which is less than the default max_split_size.
      # That is, one needs to manually set max_split_size to a higher value to use dicho.
      # If the dicho limits are changed the test needs to be corrected with new values.

      limits = { service: 500, vehicle: 10 } # Do not replace with class values, correct manually.

      limit_vrp = VRP.toy

      limit_vrp[:services] = []
      limits[:service].times{ |i|
        limit_vrp[:services] << { id: "s#{i + 1}", activity: { point_id: 'p1' }}
      }

      limit_vrp[:vehicles] = []
      limits[:vehicle].times{ |i|
        limit_vrp[:vehicles] << { id: "v#{i + 1}", router_mode: 'car', router_dimension: 'time', skills: [[]] }
      }
      limit_vrp[:configuration] = {
        resolution: {
          dicho_algorithm_service_limit: limits[:service],
          dicho_algorithm_vehicle_limit: limits[:vehicle],
        }
      }

      vrp = TestHelper.create(limit_vrp)
      refute Interpreters::Dichotomous.dichotomous_candidate?(
        Models::ResolutionContext.new(vrp: vrp, service: :demo, dicho_level: 0)
      )

      vrp = limit_vrp.dup
      vrp[:vehicles] = limit_vrp[:vehicles].dup
      vrp[:vehicles] << { id: "v#{limits[:vehicle] + 1}", router_mode: 'car', router_dimension: 'time', skills: [[]] }
      vrp = TestHelper.create(vrp)
      refute Interpreters::Dichotomous.dichotomous_candidate?(
        Models::ResolutionContext.new(vrp: vrp, service: :demo, dicho_level: 0)
      )

      vrp = limit_vrp.dup
      vrp[:services] = limit_vrp[:services].dup
      vrp[:services] << { id: "s#{limits[:service] + 1}", activity: { point_id: 'p1' }}
      vrp = TestHelper.create(vrp)
      refute Interpreters::Dichotomous.dichotomous_candidate?(
        Models::ResolutionContext.new(vrp: vrp, service: :demo, dicho_level: 0)
      )

      vrp = limit_vrp.dup
      vrp[:services] << { id: "s#{limits[:service] + 1}", activity: { point_id: 'p1' }}
      vrp[:vehicles] << { id: "v#{limits[:vehicle] + 1}", router_mode: 'car', router_dimension: 'time', skills: [[]] }
      vrp = TestHelper.create(vrp)
      refute Interpreters::Dichotomous.dichotomous_candidate?(
        Models::ResolutionContext.new(vrp: vrp, service: :demo, dicho_level: 0)
      )

      vrp.vehicles.each{ |v| v.duration = 36000 }
      assert Interpreters::Dichotomous.dichotomous_candidate?(
        Models::ResolutionContext.new(vrp: vrp, service: :demo, dicho_level: 0)
      )

      vrp.configuration.resolution.dicho_algorithm_service_limit = 0
      refute Interpreters::Dichotomous.dichotomous_candidate?(
        Models::ResolutionContext.new(vrp: vrp, service: :demo, dicho_level: 0)
      )
    end

    def test_allocate_children_time_budget_respects_total
      parent_vrp = TestHelper.create(VRP.toy)
      parent_vrp.configuration.resolution.duration = 10_000
      parent = Models::ResolutionContext.new(
        vrp: parent_vrp,
        dicho_level: 0,
        resolution_time_budget_ms: 10_000,
        original_duration_ms: 10_000
      )

      child_a_vrp = TestHelper.create(VRP.toy)
      child_a_vrp.services = parent_vrp.services.first(6)
      child_a_vrp.vehicles = parent_vrp.vehicles.first(2)
      child_b_vrp = TestHelper.create(VRP.toy)
      child_b_vrp.services = parent_vrp.services.first(4)
      child_b_vrp.vehicles = parent_vrp.vehicles.first(4)

      child_a = Models::ResolutionContext.new(vrp: child_a_vrp, dicho_level: 1)
      child_b = Models::ResolutionContext.new(vrp: child_b_vrp, dicho_level: 1)

      Interpreters::Dichotomous.allocate_children_time_budget!(parent, [child_a, child_b])

      total_weight =
        Interpreters::Dichotomous.dicho_sub_vrp_weight(child_a_vrp) +
        Interpreters::Dichotomous.dicho_sub_vrp_weight(child_b_vrp)
      expected_a = (10_000 * Interpreters::Dichotomous.dicho_sub_vrp_weight(child_a_vrp) / total_weight).floor
      expected_b = (10_000 * Interpreters::Dichotomous.dicho_sub_vrp_weight(child_b_vrp) / total_weight).floor

      assert_equal expected_a, child_a.resolution_time_budget_ms
      assert_equal expected_b, child_b.resolution_time_budget_ms
      assert_operator child_a.resolution_time_budget_ms + child_b.resolution_time_budget_ms, :<=, 10_000
    end

    def test_dichotomous_time_budget_helpers
      vrp = TestHelper.create(VRP.toy)
      vrp.configuration.resolution.duration = 10_000
      vrp.configuration.resolution.dicho_end_stage_enabled = false
      vrp.configuration.resolution.dicho_end_stage_time_share = nil
      service_vrp = Models::ResolutionContext.new(vrp: vrp, service: :ortools, dicho_level: 0, dicho_data: {})

      Interpreters::Dichotomous.ensure_time_budget!(service_vrp)
      assert_equal 10_000, service_vrp.resolution_time_budget_ms
      assert_equal 10_000, service_vrp.original_duration_ms

      assert Interpreters::Dichotomous.apply_solve_duration_cap!(service_vrp)
      assert_equal 10_000, vrp.configuration.resolution.duration

      service_vrp.resolution_time_budget_ms = 100
      refute Interpreters::Dichotomous.apply_solve_duration_cap!(service_vrp)

      service_vrp.resolution_time_budget_ms = 10_000
      Interpreters::Dichotomous.consume_time_budget!(service_vrp, 3000)
      assert_in_delta 7000, service_vrp.resolution_time_budget_ms, 0.01
    end

    def test_consume_subtree_time_budget_excludes_end_stage_wall
      parent = Models::ResolutionContext.new(
        vrp: TestHelper.create(VRP.toy),
        dicho_level: 0,
        dicho_data: {},
        resolution_time_budget_ms: 10_000
      )
      parent.dicho_data[:end_stage_wall_consumed_ms] = 2000

      Interpreters::Dichotomous.consume_subtree_time_budget!(
        parent,
        5000,
        end_stage_wall_before: 0
      )

      # 5000ms subtree wall, 2000ms end_stage excluded → only 3000ms charged to main budget
      assert_in_delta 7000, parent.resolution_time_budget_ms, 0.01
    end

    def test_ensure_time_budget_reserves_end_stage_share
      vrp = TestHelper.create(VRP.toy)
      vrp.configuration.resolution.duration = 10_000
      vrp.configuration.resolution.dicho_end_stage_time_share = 0.25
      service_vrp = Models::ResolutionContext.new(vrp: vrp, service: :ortools, dicho_level: 0, dicho_data: {})

      Interpreters::Dichotomous.ensure_time_budget!(service_vrp)

      assert_equal 7500, service_vrp.resolution_time_budget_ms
      assert_equal 2500, service_vrp.dicho_data[:end_stage_time_budget_ms]
      assert_equal 2500, service_vrp.dicho_data[:end_stage_time_budget_initial_ms]
    end

    def test_dichotomous_solve_durations_within_budget
      problem = dicho_lat_lon_problem(duration: 8000)
      problem.configuration.resolution.minimum_duration = 100

      max_duration = problem.configuration.resolution.duration
      recorded_durations = []

      with_fast_dicho_heuristic(problem) do |service_vrp|
        with_stubbed_dicho_orchestration(
          recorded_durations: recorded_durations,
          elapsed: ->(svrp){ [svrp.vrp.configuration.resolution.duration.to_i / 2, 50].max }
        ) do
          Interpreters::Dichotomous.dichotomous_heuristic(service_vrp, nil)
        end
      end

      assert recorded_durations.any?, 'Expected at least one dichotomous solve call'
      assert_operator recorded_durations.sum, :<=, max_duration * 1.05,
                      "Sum of solve durations (#{recorded_durations.sum}) exceeds budget (#{max_duration})"
    end

    def test_dichotomous_self_selection_runs_once_on_first_viable_sub_vrp
      problem = dicho_lat_lon_problem
      problem.configuration.preprocessing.first_solution_strategy = 'self_selection'

      find_best_calls = 0
      stub_find_best =
        lambda{ |service_vrp_in|
          find_best_calls += 1
          service_vrp_in.vrp.configuration.preprocessing.first_solution_strategy = ['savings']
          Interpreters::SeveralSolutions.store_selected_first_solution_strategy!(service_vrp_in)
          service_vrp_in
        }

      with_fast_dicho_heuristic(problem) do |service_vrp|
        Interpreters::SeveralSolutions.stub(:find_best_heuristic, stub_find_best) do
          with_stubbed_dicho_orchestration do
            Interpreters::Dichotomous.dichotomous_heuristic(service_vrp, nil)
          end
        end

        assert_equal 1, find_best_calls,
                     'self_selection should invoke find_best_heuristic only once on the first viable sub-vrp'
        assert_equal 'savings', service_vrp.selected_first_solution_strategy
      end
      refute Interpreters::SeveralSolutions.self_selection?(
        problem.configuration.preprocessing.first_solution_strategy
      )
    end

    def test_dichotomous_construction_timings_after_split
      problem = dicho_lat_lon_problem

      with_fast_dicho_heuristic(problem) do |service_vrp|
        with_stubbed_dicho_orchestration do
          Interpreters::Dichotomous.dichotomous_heuristic(service_vrp, nil)
        end

        timings = service_vrp.dicho_data[:construction_timings]
        assert timings, 'construction_timings should be populated after dichotomous split'
        assert_operator timings[:splits_count], :>=, 1
        assert_operator Interpreters::DichoConstructionTimings.total_ms(timings), :>=, 0
      end
    end

    def test_infinite_loop_due_to_impossible_to_cluster
      vrp = VRP.lat_lon
      vrp[:configuration][:resolution][:duration] = 20
      vrp[:points].each{ |p| p[:location] = { lat: 45, lon: 5 } } # all at the same location (impossible to cluster)

      vrp[:matrices][0][:time] = Array.new(7){ Array.new(7, 1) }
      vrp[:matrices][0][:time].each_with_index{ |row, i| row[i] = 0 }
      vrp[:matrices][0][:distance] = vrp[:matrices][0][:time]

      vrp[:services].each{ |s| s[:activity][:duration] = 500 }

      vrp[:vehicles].first[:duration] = 3600
      vrp[:vehicles] << vrp[:vehicles].first.dup
      vrp[:vehicles].last[:id] = 'v_1'

      problem = TestHelper.create(vrp)

      problem.configuration.resolution.dicho_algorithm_vehicle_limit = 1
      problem.configuration.resolution.dicho_division_vehicle_limit = 1
      problem.configuration.resolution.dicho_algorithm_service_limit = 5
      problem.configuration.resolution.dicho_division_service_limit = 5

      counter = 0
      level = nil
      Interpreters::Dichotomous.stub(:split, lambda{ |vrpi, cut_symbol|
        assert_operator counter, :<, 3,
                        'Interpreters::Dichotomous::split is called too many times. '\
                        'Either there is an infinite loop due to imposible clustering or dicho split logic is altered.'

        if vrpi[:dicho_level] != level
          level = vrpi[:dicho_level]
          counter = 1
        else
          counter += 1
        end

        Interpreters::Dichotomous.send(:__minitest_stub__split, vrpi, cut_symbol)
      }) do
        OptimizerWrapper.wrapper_vrp('ortools', { services: { vrp: [:ortools] }}, problem, nil)
      end
    end

    def test_cluster_dichotomous_heuristic
      # Warning: This test is not enough to ensure that two services at the same point will
      # not end up in two different routes because after clustering there is tsp_simple.
      # In fact this check is too limiting because for this test to pass we deactivate
      # balancing in dicho_split at the last iteration.

      # TODO: Instead of deactivating balancing we can implement
      # clique like preprocessing inside clustering that way it would be impossible for
      # two very close service ending up in two different routes.
      # Moreover, it would increase the performance of clustering.
      vrp = TestHelper.load_vrp(self, fixture_file: 'cluster_dichotomous')
      vrp.vehicles = vrp.vehicles[0..60] # no need for all vehicles
      service_vrp =
        Models::ResolutionContext.new(
          vrp: vrp,
          service: :demo,
          dicho_level: 0,
          dicho_denominators: [1],
          dicho_sides: [0]
        )
      while service_vrp.vrp.services.size > 100
        services_vrps_dicho = Interpreters::Dichotomous.split(service_vrp, nil)
        assert_equal 2, services_vrps_dicho.size

        locations_one =
          services_vrps_dicho.first.vrp.services.map{ |s|
            [s.activity.point.location.lat, s.activity.point.location.lon]
          }                         # clusters.first.data_items.map{ |d| [d[0], d[1]] }
        locations_two =
          services_vrps_dicho.second.vrp.services.map{ |s|
            [s.activity.point.location.lat, s.activity.point.location.lon]
          }                         # clusters.second.data_items.map{ |d| [d[0], d[1]] }
        # split is done by vehicle + by representative_vrp so this might lead to some points get split between sides
        # but this should not be an issue because the optimisation should handle such points if they can be performed
        # on the same vehicle.
        # The solution is to improve the vehicle_compatibility logic and using it inside collect_data
        assert_operator 3, :>=, (locations_one & locations_two).size, 'There should not be too many "split" points'

        durations = []
        services_vrps_dicho.each{ |service_vrp_dicho|
          durations << service_vrp_dicho.vrp.services_duration
        }
        assert_equal service_vrp.vrp.services_duration.to_i, durations.sum.to_i
        assert services_vrps_dicho[0].vrp.vehicles.size >= services_vrps_dicho[1].vrp.vehicles.size,
               'Dicho should start solving the side with more vehicles first'

        average_duration = durations.sum / durations.size
        # Clusters should be balanced but the priority is the geometry
        range = 0.6
        min_duration = (1.0 - range) * average_duration
        max_duration = (1.0 + range) * average_duration
        durations.each_with_index{ |duration, index|
          assert duration < max_duration && duration > min_duration,
                 "Duration ##{index} (#{duration}) should be between #{min_duration} and #{max_duration}"
        }

        service_vrp = services_vrps_dicho.min_by{ |sv| sv.vrp.services_duration }
      end
    end

    def test_no_dichotomous_when_no_location
      problem = VRP.basic
      problem[:vehicles].each{ |v| v[:duration] = 36000 }
      problem[:vehicles] << problem[:vehicles].first.merge({ id: 'another_vehicle' })
      problem[:configuration][:resolution][:dicho_algorithm_service_limit] = 1
      vrp = TestHelper.create(problem)
      service_vrp = Models::ResolutionContext.new(vrp: vrp, service: :demo)

      vrp.configuration.resolution.dicho_algorithm_vehicle_limit = 1

      refute Interpreters::Dichotomous.dichotomous_candidate?(service_vrp), 'no dicho if no location'

      location = Models::Location.new(lat: 0, lon: 0)
      vrp.points.map!{ |point| point.tap{ |p| p.location = location } }

      assert Interpreters::Dichotomous.dichotomous_candidate?(service_vrp), 'dicho if all has location'
    end

    def test_split_function_with_services_at_same_location
      vrp = TestHelper.load_vrp(self, fixture_file: 'two_phases_clustering_sched_with_freq_and_same_point_day_5veh')
      assert vrp.services.group_by{ |s| s.activity.point_id }.any?{ |_pt_id, set| set.size > 1 },
             'This test is useless if there are not several services with same point_id'
      service_vrp = Models::ResolutionContext.new(vrp: vrp, dicho_sides: [], dicho_denominators: [], dicho_level: 0)
      split = Interpreters::Dichotomous.send(:split, service_vrp)
      assert_equal 2, split.size
      assert_equal vrp.services.size, split.sum{ |s| s.vrp.services.size }, 'Wrong number of services returned'
    end

    def test_rest_cannot_appear_as_a_mission_in_the_initial_route
      rest = Models::Rest.new(id: 'id')
      route_rest = Models::Solution::Stop.new(rest)
      solution_route = Models::Solution::Route.new(stops: [route_rest])
      initial_solution = Models::Solution.new(routes: [solution_route])
      assert_empty Interpreters::Dichotomous.send(:build_initial_routes, [initial_solution])
    end

    def test_end_stage_skip_when_explicitly_disabled
      vrp = TestHelper.create(VRP.toy)
      vrp.configuration.resolution.dicho_end_stage_enabled = false
      service_vrp = Models::ResolutionContext.new(vrp: vrp, dicho_level: 0, dicho_data: {})
      Interpreters::DichoResolutionTimings.ensure!(service_vrp.dicho_data)

      solution = Models::Solution.new(
        unassigned_stops: vrp.services.map{ |service| Models::Solution::Stop.new(service) }
      )

      refute Interpreters::DichoEndStageSolver.end_stage_active?(service_vrp, solution)
      assert_equal 1,
                   Interpreters::DichoResolutionTimings.for_dicho_data(service_vrp.dicho_data)[:end_stage_skipped_count]
    end

    def test_skipped_child_on_deadline_preserves_visit_count
      vrp_data = VRP.lat_lon
      vrp_data[:configuration][:resolution][:duration] = 60_000
      vrp_data[:services] = vrp_data[:services].first(8)
      vrp_data[:vehicles] << vrp_data[:vehicles].first.dup
      vrp_data[:vehicles].last[:id] = 'v_1'

      problem = TestHelper.create(vrp_data)
      assert_operator problem.vehicles.size, :>, 1, 'Dicho split requires at least two vehicles'
      assert_operator problem.services.size, :>, 5, 'Dicho split requires more services than dicho_division_service_limit'
      problem.configuration.resolution.dicho_algorithm_vehicle_limit = 1
      problem.configuration.resolution.dicho_division_vehicle_limit = 1
      problem.configuration.resolution.dicho_algorithm_service_limit = 5
      problem.configuration.resolution.dicho_division_service_limit = 5

      parent = Models::ResolutionContext.new(
        vrp: problem,
        service: :ortools,
        dicho_level: 0,
        dicho_sides: [],
        dicho_denominators: []
      )
      children = Interpreters::Dichotomous.send(:split, parent)
      assert_equal 2, children.size
      assert_equal problem.services.size, (children.sum{ |child| child.vrp.services.size })

      first_child = children.first.vrp
      route = problem.empty_route(first_child.vehicles.first)
      first_child.services.each{ |service| route.stops << Models::Solution::Stop.new(service) }
      first_child_solution = Models::Solution.new(routes: [route], unassigned_stops: [])

      merged =
        Interpreters::Dichotomous.send(
          :merge_dicho_children_solutions,
          parent,
          [first_child_solution],
          [children.last]
        )

      Core::Components::Solution.check_solutions_consistency(problem.visits, [merged])
      assert_equal children.last.vrp.services.size, merged.count_unassigned_services
      assert(
        merged.unassigned_stops.all?{ |stop|
          stop.reason == Interpreters::Dichotomous::RESOLUTION_DEADLINE_UNASSIGNED_REASON
        }
      )
    end

    def test_dichotomous_approach_transfer_unused_vehicles_transfers_points_correctly
      vrp = VRP.lat_lon
      vrp[:configuration][:resolution][:duration] = 6
      vrp[:vehicles].first[:duration] = 1 # no need to plan the services
      vrp[:vehicles] << vrp[:vehicles].first.dup
      vrp[:vehicles].last[:id] = 'v_1'

      Interpreters::Dichotomous.stub(:dichotomous_candidate?, lambda{ |service_vrp|
        # modify limits so that the vrp will be dicho_split one and only one time
        service_vrp.vrp.configuration.resolution.dicho_division_service_limit = 5
        service_vrp.vrp.configuration.resolution.dicho_division_vehicle_limit = 1
        true
      }) do
        Interpreters::Dichotomous.stub(:transfer_unused_vehicles, lambda{ |result, sub_service_vrps|
          sub_service_vrps[0].vrp.vehicles << Helper.deep_copy(
            sub_service_vrps[0].vrp.vehicles.last,
            override: { id: 'extra_unused_vehicle' },
            shallow_copy: [:start_point] # regenerate end_point to check
          )
          sub_service_vrps[0].vrp.points << sub_service_vrps[0].vrp.vehicles.last.end_point

          Interpreters::Dichotomous.send(:__minitest_stub__transfer_unused_vehicles, result, sub_service_vrps)

          sv_one = sub_service_vrps[1].vrp
          transferred_vehicle = sv_one.vehicles.last
          assert_equal 'extra_unused_vehicle', transferred_vehicle.id,
                       'transfer_unused_vehicles should have transfer the extra vehicle'

          point_ids = sv_one.points.map(&:id)
          assert_equal point_ids.size, point_ids.uniq.size, 'There are duplicate points after transfer_unused_vehicles'
          assert sv_one.points.any?{ |p|
                   p.object_id == transferred_vehicle.start_point.object_id
                 }, "transferred vehicle's start_point doesn't exist in points"
          assert sv_one.points.any?{ |p|
                   p.object_id == transferred_vehicle.end_point.object_id
                 }, "transferred vehicle's end_point doesn't exist in points"
        }) do
          OptimizerWrapper.wrapper_vrp('ortools', { services: { vrp: [:ortools] }}, TestHelper.create(vrp), nil)
        end
      end
    end
  end
end
