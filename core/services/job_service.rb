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

          {
            time: job.time,
            uuid: job.uuid,
            status: job.status,
            avancement: job.message,
            checksum: job.options && job.options['checksum'],
            name: job.options && job.options['vrp_name']
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

      module_function :job_list, :job_kill, :job_remove, :retention_expired?, :completed_at
    end
  end
end
