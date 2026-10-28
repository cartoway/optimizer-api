# Copyright © Cartoway, 2026
#
require './test/test_helper'

class Wrappers::PyVRPProgressTest < Minitest::Test
  def setup
    @pyvrp = Wrappers::PyVRP.new(tmp_dir: Dir.tmpdir)
  end

  def test_parse_progress_line_reads_iteration_feasible_best
    progress = @pyvrp.send(
      :parse_progress_line,
      'H     500     12s |  25     1234     1000 |  10     5000     4000'
    )

    assert_equal 500, progress[:iterations]
    assert_in_delta 1000.0, progress[:cost]
    assert_in_delta 12.0, progress[:time]
    refute progress[:final]
  end

  def test_parse_progress_line_falls_back_to_infeasible_best
    # Mimic strip: non-H lines lose their leading marker space.
    progress = @pyvrp.send(
      :parse_progress_line,
      '500     12s |   0        -        - |  10     5000     4000'
    )

    assert_equal 500, progress[:iterations]
    assert_in_delta 4000.0, progress[:cost]
    assert_in_delta 12.0, progress[:time]
  end

  def test_parse_progress_line_reads_search_terminated_and_best_cost
    terminated = @pyvrp.send(:parse_progress_line, 'Search terminated in 30.50s after 1500 iterations.')
    assert_equal 1500, terminated[:iterations]
    assert_in_delta 30.5, terminated[:time]
    assert terminated[:final]

    best = @pyvrp.send(:parse_progress_line, 'Best-found solution has cost 950.25.')
    assert_in_delta 950.25, best[:cost]
    assert best[:final]
  end

  def test_run_pyvrp_progress_calls_block_like_ortools
    status = Object.new
    def status.success? = true
    fake_thread = Struct.new(:value, :alive?, :pid).new(status, false, 1)
    progress_lines = [
      "H     500     12s |  25     1234     1000 |  10     5000     4000\n",
      # Leading spaces are stripped before parse (same as the live reader).
      "     1000     25s |  25     1200      950 |  10     4800     3900\n",
      "Search terminated in 30.00s after 1500 iterations.\n",
      "Best-found solution has cost 950.0.\n"
    ]
    stdout = StringIO.new(progress_lines.join)

    calls = []
    Open3.stub(:popen2e, lambda { |cmd, *|
      path = cmd[/\S*optimize-pyvrp-output\S*/]
      File.write(path, '{"feasible":true,"routes":[],"cost":950,"runtime":30,"iterations":1500}')
      [StringIO.new, stdout, fake_thread]
    }) do
      @pyvrp.stub(:pyvrp_python, 'python3') do
        result = @pyvrp.send(:run_pyvrp, {}, 1) { |*args| calls << args }
        assert_equal 1500, result[:iterations]
      end
    end

    assert_equal 4, calls.size
    assert_equal [@pyvrp, 500, nil, nil, 1000.0, 12.0, nil], calls[0]
    assert_equal [@pyvrp, 1000, nil, nil, 950.0, 25.0, nil], calls[1]
    assert_equal [@pyvrp, 1500, nil, nil, 950.0, 30.0, nil], calls[2]
    assert_equal [@pyvrp, 1500, nil, nil, 950.0, 30.0, nil], calls[3]
  end
end
