module Core
  module Services
    module JobService
      # Keep completed jobs listable/retrievable for a few hours after resolution ends.
      COMPLETED_RETENTION = (ENV['OPTIM_JOB_RETENTION_HOURS'] || 4).to_i.hours

      def job_list(api_key)
        (OptimizerWrapper::JobList.get(api_key) || []).filter_map{ |e|
          job = Resque::Plugins::Status::Hash.get(e)
          if job.nil?
            OptimizerWrapper::Result.remove(api_key, e)
            next
          end
          if retention_expired?(job)
            job_remove(api_key, e)
            next
          end

          options = job.options || {}
          {
            time: job.time,
            uuid: job.uuid,
            status: job.status,
            avancement: job.message,
            checksum: options['checksum'],
            name: options['vrp_name'],
            vrp_dump: vrp_dump?(api_key, job)
          }
        }
      end

      def job_kill(_api_key, id)
        Resque::Plugins::Status::Hash.kill(id) # Worker will be killed at the next call of at() method
      end

      def job_remove(api_key, id)
        OptimizerWrapper::Result.remove(api_key, id)
        # remove only queued jobs
        if Resque::Plugins::Status::Hash.get(id)
          OptimizerWrapper::Job.dequeue(OptimizerWrapper::Job, id)
          Resque::Plugins::Status::Hash.remove(id)
        end
      end

      def vrp_dump_key(api_key, vrp_name, checksum)
        return unless checksum

        key_print = api_key.to_s.rpartition('-')[0]
        key_print = api_key.to_s[0..3] if key_print.empty?
        [key_print, vrp_name.presence || 'no_vrp_name', checksum].compact.join('_')
      end

      def read_vrp_dump(api_key, job)
        return unless job&.dig('options', 'api_key') == api_key

        options = job.options || {}
        key = options['vrp_dump_key'].presence || vrp_dump_key(api_key, options['vrp_name'], options['checksum'])
        return unless key

        OptimizerWrapper.dump_vrp_dir.read(key)
      end

      def vrp_dump?(api_key, job)
        return false unless job&.dig('options', 'checksum')

        options = job.options || {}
        key = options['vrp_dump_key'].presence || vrp_dump_key(api_key, options['vrp_name'], options['checksum'])
        return false unless key

        OptimizerWrapper.dump_vrp_dir.exist?(key)
      end

      def retention_expired?(job)
        return false unless job&.completed?

        finished_at = completed_at(job)
        return false unless finished_at

        Time.now - finished_at >= COMPLETED_RETENTION
      end

      def completed_at(job)
        message = job.message.to_s
        if (match = message.match(/\ACompleted at (.+)\z/))
          Time.parse(match[1])
        else
          job.time
        end
      rescue ArgumentError, TypeError
        job.time
      end

      module_function :job_list, :job_kill, :job_remove, :vrp_dump_key, :read_vrp_dump, :vrp_dump?,
                      :retention_expired?, :completed_at
    end
  end
end
