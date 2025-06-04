module Core
  module Services
    module JobService
      def job_list(api_key)
        (OptimizerWrapper::JobList.get(api_key) || []).collect{ |e|
          if job = Resque::Plugins::Status::Hash.get(e) # rubocop: disable Lint/AssignmentInCondition
            {
              time: job.time,
              uuid: job.uuid,
              status: job.status,
              avancement: job.message,
              checksum: job.options && job.options['checksum']
            }
          else
            OptimizerWrapper::Result.remove(api_key, e)
          end
        }.compact
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
      module_function :job_list, :job_kill, :job_remove
    end
  end
end
