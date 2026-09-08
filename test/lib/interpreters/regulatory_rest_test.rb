require './test/test_helper'

class Interpreters::RegulatoryRestTest < IsolatedTest
  def regulatory_problem
    {
      matrices: [{
        id: 'matrix_0',
        time: [
          [0, 3600, 3600, 3600],
          [3600, 0, 3600, 3600],
          [3600, 3600, 0, 3600],
          [3600, 3600, 3600, 0]
        ]
      }],
      points: [
        { id: 'point_0', matrix_index: 0 },
        { id: 'point_1', matrix_index: 1 },
        { id: 'point_2', matrix_index: 2 },
        { id: 'point_3', matrix_index: 3 }
      ],
      rests: [{
        id: 'reg_rest',
        duration: 2700,
        lapse: 21600
      }],
      vehicles: [{
        id: 'vehicle_0',
        matrix_id: 'matrix_0',
        start_point_id: 'point_0',
        end_point_id: 'point_0',
        rest_ids: ['reg_rest'],
        timewindow: { start: 0, end: 43200 }
      }],
      services: [{
        id: 'service_1',
        activity: {
          point_id: 'point_1',
          duration: 3600,
          timewindows: [{ start: 21600, end: 28800 }]
        }
      }, {
        id: 'service_2',
        activity: { point_id: 'point_2', duration: 3600 }
      }, {
        id: 'service_3',
        activity: { point_id: 'point_3', duration: 3600 }
      }],
      configuration: {
        resolution: { duration: 100 },
        restitution: { intermediate_solutions: false }
      }
    }
  end

  def pause_problem
    {
      matrices: [{
        id: 'matrix_0',
        time: [
          [0, 30, 30, 30],
          [30, 0, 30, 30],
          [30, 30, 0, 30],
          [30, 30, 30, 0]
        ]
      }],
      points: [
        { id: 'point_0', matrix_index: 0 },
        { id: 'point_1', matrix_index: 1 },
        { id: 'point_2', matrix_index: 2 },
        { id: 'point_3', matrix_index: 3 }
      ],
      rests: [{
        id: 'reg_rest',
        duration: 10,
        lapse: 100
      }],
      vehicles: [{
        id: 'vehicle_0',
        matrix_id: 'matrix_0',
        start_point_id: 'point_0',
        end_point_id: 'point_0',
        rest_ids: ['reg_rest'],
        timewindow: { start: 0, end: 1000 }
      }],
      services: [{
        id: 'service_1',
        activity: { point_id: 'point_1', duration: 80 }
      }, {
        id: 'service_2',
        activity: { point_id: 'point_2', duration: 80 }
      }, {
        id: 'service_3',
        activity: { point_id: 'point_3', duration: 80 }
      }],
      configuration: {
        resolution: { duration: 100 },
        restitution: { intermediate_solutions: false }
      }
    }
  end

  def sequential_solution(vrp)
    vehicle = vrp.vehicles.first
    info = -> { Models::Solution::Stop::Info.new(begin_time: 0, end_time: 0, departure_time: 0) }
    stops = [Models::Solution::StopDepot.new(vehicle.start_point, info: info.call)]
    vrp.services.each{ |service| stops << Models::Solution::Stop.new(service, info: info.call) }
    stops << Models::Solution::StopDepot.new(vehicle.end_point, info: info.call)
    Models::Solution.new(
      routes: [
        Models::Solution::Route.new(
          vehicle: vehicle,
          stops: stops,
          info: Models::Solution::Route::Info.new(start_time: 0, end_time: 0)
        )
      ]
    )
  end

  def uniform_time_matrix(value)
    [
      [0, value, value, value],
      [value, 0, value, value],
      [value, value, 0, value],
      [value, value, value, 0]
    ]
  end

  def patched_stops(problem)
    vrp = TestHelper.create(problem)
    solution = sequential_solution(vrp)
    Interpreters::RegulatoryRest.new.patch_solution!(vrp, solution)
    [vrp, solution.routes.first.stops]
  end

  def test_not_applicable_without_lapse
    problem = regulatory_problem
    problem[:rests].first.delete(:lapse)
    vrp = TestHelper.create(problem)

    refute Interpreters::RegulatoryRest.applicable?(vrp)
  end

  def test_inflates_durations_and_delays_timewindow_starts_only
    vrp = TestHelper.create(regulatory_problem)
    interpreter = Interpreters::RegulatoryRest.new

    assert interpreter.apply!(vrp)

    # 45min every 6h → rate 0.125, so 1h of work becomes 1h07m30s (not +15min)
    assert_equal 4050, vrp.services.find{ |s| s.id == 'service_1' }.activity.duration
    assert_equal 4050, vrp.matrices.first.time[0][1]
    # start 21600 from tour_start 0 → +2700; end stays 28800
    assert_equal 24300, vrp.services.find{ |s| s.id == 'service_1' }.activity.timewindows.first.start
    assert_equal 28800, vrp.services.find{ |s| s.id == 'service_1' }.activity.timewindows.first.end
    assert_equal 43200, vrp.vehicles.first.timewindow.end
    assert_empty vrp.vehicles.first.rests
    refute_includes OptimizerWrapper.config[:services][:pyvrp].inapplicable_solve?(vrp), :assert_no_rest
  end

  def test_inflate_ceils_fractional_durations_and_start_delay
    problem = pause_problem
    problem[:rests].first[:lapse] = 120
    problem[:services].first[:activity][:timewindows] = [{ start: 100, end: 200 }]
    vrp = TestHelper.create(problem)

    Interpreters::RegulatoryRest.new.apply!(vrp)

    # 80 * 13/12 = 86.66… → 87; 30 * 13/12 = 32.5 → 33
    assert_equal 87, vrp.services.first.activity.duration
    assert_equal 33, vrp.matrices.first.time[0][1]
    tw = vrp.services.first.activity.timewindows.first
    # extra 100/12 = 8.33… → start 109; end unchanged
    assert_equal 109, tw.start
    assert_equal 200, tw.end
  end

  def test_timewindow_start_delay_is_capped_at_pause_duration
    problem = pause_problem
    problem[:services].last[:activity][:timewindows] = [{ start: 500, end: 800 }]
    vrp = TestHelper.create(problem)

    Interpreters::RegulatoryRest.new.apply!(vrp)

    # Linear extra would be 500 * 0.1 = 50; cap at duration 10.
    tw = vrp.services.find{ |s| s.id == 'service_3' }.activity.timewindows.first
    assert_equal 510, tw.start
    assert_equal 800, tw.end
  end

  def test_rewind_restores_original_problem
    vrp = TestHelper.create(regulatory_problem)
    interpreter = Interpreters::RegulatoryRest.new
    interpreter.apply!(vrp)
    interpreter.rewind!(vrp)

    assert_equal 3600, vrp.services.find{ |s| s.id == 'service_1' }.activity.duration
    assert_equal 3600, vrp.matrices.first.time[0][1]
    assert_equal 21600, vrp.services.find{ |s| s.id == 'service_1' }.activity.timewindows.first.start
    assert_equal 28800, vrp.services.find{ |s| s.id == 'service_1' }.activity.timewindows.first.end
    assert_equal 43200, vrp.vehicles.first.timewindow.end
    assert_equal 1, vrp.vehicles.first.rests.size
    assert_equal 21600, vrp.vehicles.first.rests.first.lapse
  end

  def test_patch_inserts_repeatable_pauses_from_accumulated_work
    _vrp, stops = patched_stops(pause_problem)

    rest_stops = stops.select{ |stop| stop.type == :rest }
    assert_equal 3, rest_stops.size, 'A pause is due after each 100s of work (three services)'
    assert(rest_stops.all?{ |stop| stop.activity.duration == 10 })
    assert_equal [:depot, :service, :rest, :service, :rest, :service, :rest, :depot], stops.map(&:type)
  end

  def test_patch_inserts_pause_after_service_when_lapse_exceeded_during_service
    problem = pause_problem
    problem[:matrices].first[:time] = uniform_time_matrix(10)
    problem[:services].each{ |service| service[:activity][:duration] = 40 }
    problem[:services][1][:activity][:timewindows] = [{ start: 0, end: 1000 }]

    _vrp, stops = patched_stops(problem)

    # Travel does not complete the lapse, service does → rest after S2 even if the TW would allow a pause before.
    assert_equal [:depot, :service, :service, :rest, :service, :depot], stops.map(&:type)
  end

  def test_patch_inserts_pause_before_travel_that_would_exceed_lapse
    problem = pause_problem
    problem[:matrices].first[:time] = uniform_time_matrix(10)
    problem[:services].each{ |service| service[:activity][:duration] = 85 }

    _vrp, stops = patched_stops(problem)

    # After S1 work is 95s; the next 10s drive would complete the lapse → rest before travelling.
    assert_equal [:depot, :service, :rest, :service, :rest, :service, :rest, :depot], stops.map(&:type)
  end

  def test_patch_inserts_pause_after_stop_when_before_would_miss_timewindow
    problem = pause_problem
    problem[:rests].first[:duration] = 20
    problem[:matrices].first[:time] = uniform_time_matrix(10)
    problem[:services].each{ |service| service[:activity][:duration] = 85 }
    problem[:services][1][:activity][:timewindows] = [{ start: 105, end: 110 }]

    _vrp, stops = patched_stops(problem)

    assert_equal [:depot, :service, :service, :rest, :service, :rest, :depot], stops.map(&:type)
    assert_equal 105, stops.find{ |stop| stop.service_id == 'service_2' }.info.begin_time
  end

  def test_lapse_rests_do_not_skip_any_solver
    vrp = TestHelper.create(regulatory_problem)

    assert_empty Interpreters::RegulatoryRest.solver_rests(vrp.vehicles.first)
    %i[pyvrp vroom ortools].each{ |solver|
      refute_includes OptimizerWrapper.config[:services][solver].inapplicable_solve?(vrp), :assert_no_rest,
                      "#{solver} must not skip because of a regulatory (lapse) rest"
    }
  end

  def test_pyvrp_still_rejects_classic_rests
    problem = regulatory_problem
    problem[:rests].first.delete(:lapse)
    problem[:rests].first[:duration] = 600
    vrp = TestHelper.create(problem)

    assert_includes OptimizerWrapper.config[:services][:pyvrp].inapplicable_solve?(vrp), :assert_no_rest
  end

  def test_apply_then_patch_restores_durations_and_inserts_pauses
    vrp = TestHelper.create(pause_problem)
    interpreter = Interpreters::RegulatoryRest.new
    interpreter.apply!(vrp)

    assert_equal 88, vrp.services.first.activity.duration

    solution = sequential_solution(vrp)
    interpreter.patch_solution!(vrp, solution)

    assert_equal 80, vrp.services.first.activity.duration
    assert_equal 30, vrp.matrices.first.time[0][1]
    assert_equal 1, vrp.vehicles.first.rests.size
    assert_equal(3, solution.routes.first.stops.count{ |stop| stop.type == :rest })
  end

  def test_rejects_heterogeneous_inflation_rates
    problem = regulatory_problem
    problem[:rests] << { id: 'other_rest', duration: 600, lapse: 3600 }
    problem[:vehicles] << {
      id: 'vehicle_1',
      matrix_id: 'matrix_0',
      start_point_id: 'point_0',
      rest_ids: ['other_rest']
    }
    vrp = TestHelper.create(problem)

    assert_raises OptimizerWrapper::UnsupportedProblemError do
      Interpreters::RegulatoryRest.new.apply!(vrp)
    end
  end

  def test_rejects_lapse_not_greater_than_duration
    problem = regulatory_problem
    problem[:rests].first[:duration] = 21600

    assert_raises OptimizerWrapper::DiscordantProblemError do
      TestHelper.create(problem)
    end
  end
end
