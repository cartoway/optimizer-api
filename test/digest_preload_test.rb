# Copyright © Cartoway, 2026
#
require './test/test_helper'

class DigestPreloadTest < Minitest::Test
  def test_digest_md5_is_preloaded_at_boot
    assert Digest.const_defined?(:MD5, false),
           'Digest::MD5 must be required at boot to avoid Puma thread races'
  end

  def test_concurrent_md5_hexdigest
    errors = Queue.new
    results = Queue.new

    threads =
      Array.new(8){
        Thread.new{
          begin
            100.times{ |i|
              results << Digest::MD5.hexdigest("payload-#{i}-#{Thread.current.object_id}")
            }
          rescue StandardError => e
            errors << e
          end
        }
      }
    threads.each(&:join)

    assert_equal 0, errors.size, ->{ Array.new(errors.size){ errors.pop }.inspect }
    assert_equal 800, results.size
  end
end
