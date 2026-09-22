# Copyright © Cartoway, 2026
#
require './test/test_helper'

module Models
  class BaseThreadIsolationTest < Minitest::Test
    def test_concurrent_create_and_delete_all_are_thread_local
      ready = Queue.new
      proceed = Queue.new
      deleted = Queue.new
      results = Queue.new

      threads =
        Array.new(2){ |i|
          Thread.new{
            Models.delete_all
            point = Models::Point.create(id: "thread_#{i}_point", matrix_index: i)
            assert_equal 1, Models::Point.all.size
            assert_equal point.id, Models::Point.find("thread_#{i}_point").id

            ready << i
            proceed.pop

            if i.zero?
              Models.delete_all
              assert_empty Models::Point.all
              deleted << true
            else
              deleted.pop
              assert_equal 1, Models::Point.all.size
              assert_equal "thread_#{i}_point", Models::Point.first.id
            end
            results << [i, Models::Point.all.map(&:id)]
          }
        }

      2.times{ ready.pop }
      2.times{ proceed << true }
      threads.each(&:join)

      by_thread = Array.new(2){ results.pop }.to_h
      assert_empty by_thread[0]
      assert_equal ['thread_1_point'], by_thread[1]
    ensure
      Models.delete_all
    end

    def test_concurrent_numeric_ids_do_not_collide_across_threads
      errors = Queue.new
      created = Queue.new

      threads =
        Array.new(2){
          Thread.new{
            Models.delete_all
            begin
              20.times{ |n| Models::Point.create(id: n + 1, matrix_index: n) }
              created << Models::Point.all.map(&:id).sort
            rescue StandardError => e
              errors << e
            end
          }
        }
      threads.each(&:join)

      assert_equal 0, errors.size, ->{ Array.new(errors.size){ errors.pop }.inspect }
      2.times{ assert_equal((1..20).to_a, created.pop) }
    ensure
      Models.delete_all
    end
  end
end
