require './test/test_helper'

class InterpreterTrackingTest < Minitest::Test
  def test_absorb_interpreters_from_resolution_context
    service_vrp = Models::ResolutionContext.new(vrp: TestHelper.create(VRP.toy))
    service_vrp.mark_interpreter!(:dichotomous)
    service_vrp.mark_interpreter!(:split)

    solution = Models::Solution.new({})
    solution.absorb_interpreters!(service_vrp)

    assert_equal %w[dichotomous split], solution.interpreters.sort
  end

  def test_dichotomous_marks_interpreter_as_soon_as_eligible
    service_vrp = Models::ResolutionContext.new(vrp: TestHelper.create(VRP.toy), service: :ortools)
    solution = Models::Solution.new(solvers: [:ortools])

    Interpreters::Dichotomous.stub(:dichotomous_candidate?, ->(_sv) { true }) do
      Interpreters::Dichotomous.stub(:set_config, ->(_sv) {}) do
        Interpreters::Dichotomous.stub(:ensure_time_budget!, ->(_sv) {}) do
          Interpreters::Dichotomous.stub(:build_dicho_node_solution, ->(*) { solution }) do
            result = Interpreters::Dichotomous.dichotomous_heuristic(service_vrp)
            assert_includes service_vrp.interpreters, 'dichotomous'
            assert_includes result.interpreters, 'dichotomous'
          end
        end
      end
    end
  end
end
