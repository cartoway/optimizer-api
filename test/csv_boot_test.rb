# Copyright © Cartoway, 2026
#
require './test/test_helper'

class CsvBootTest < Minitest::Test
  def test_csv_is_available_on_ruby_34
    # Ruby 3.4 removed csv from default gems; ai4r DataSet requires it at boot.
    assert_silent{ require 'csv' }
    assert CSV.parse_line('a,b'), 'csv gem must load for environment boot'
  end
end
