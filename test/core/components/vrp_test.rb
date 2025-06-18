class Core::Components::VrpTest < Minitest::Test
  include Core::Components::Vrp

  def setup
    @profile = { services: { vrp: [:demo, :ortools, :pyvrp, :vroom] } }
    @vrp = OpenStruct.new(
      configuration: OpenStruct.new(
        resolution: OpenStruct.new(
          solver_priority: []
        )
      )
    )
  end

  def test_returns_all_allowed_when_no_priority
    assert_equal [:demo, :ortools, :pyvrp, :vroom], filtered_solver_priority(@vrp, @profile)
  end

  def test_returns_intersection_when_priority_specified
    @vrp.configuration.resolution.solver_priority = ['pyvrp', 'foo']
    assert_equal [:pyvrp], filtered_solver_priority(@vrp, @profile)
  end

  def test_returns_intersection_with_specified_priority
    @vrp.configuration.resolution.solver_priority = ['pyvrp', 'ortools', 'foo']
    assert_equal [:pyvrp, :ortools], filtered_solver_priority(@vrp, @profile)
  end

  def test_returns_empty_when_no_match
    @vrp.configuration.resolution.solver_priority = ['foo']
    assert_empty filtered_solver_priority(@vrp, @profile)
  end
end
