# frozen_string_literal: true

require "redlock"
require "sbmt/outbox/v2/box_processor"
require "sbmt/outbox/v2/redis_job"
require "sbmt/outbox/v2/tasks/process"

module Sbmt
  module Outbox
    module V2
      class Processor < BoxProcessor
        delegate :processor_config, :batch_process_middlewares, :logger, to: "Sbmt::Outbox"
        attr_reader :lock_timeout, :brpop_delay

        def initialize(
          boxes,
          threads_count: nil,
          lock_timeout: nil,
          brpop_delay: nil,
          redis: nil
        )
          @lock_timeout = lock_timeout || processor_config.general_timeout
          @brpop_delay = brpop_delay || processor_config.brpop_delay

          super(boxes: boxes, threads_count: threads_count || processor_config.threads_count, name: "processor", redis: redis)
        end

        def process_task(_worker_number, task)
          middlewares = Middleware::Builder.new(batch_process_middlewares)
          middlewares.call(task) { process(task) }
        end

        private

        def build_task_queue(boxes)
          # queue size is: boxes_count * threads_count
          # to simplify scheduling per box
          tasks = boxes.map do |item_class|
            (0...threads_count)
              .to_a
              .map { Tasks::Base.new(item_class: item_class, worker_name: worker_name) }
          end.flatten

          tasks.shuffle!
          Queue.new.tap { |queue| tasks.each { |task| queue << task } }
        end

        def lock_task(scheduled_task)
          redis_job = fetch_redis_job(scheduled_task)
          return yield(nil) if redis_job.blank?

          processor_task = Tasks::Process.new(
            item_class: scheduled_task.item_class,
            worker_name: worker_name,
            bucket: redis_job.bucket,
            ids: redis_job.ids
          )
          lock_manager.lock("#{processor_task.resource_path}:lock", lock_timeout * 1000) do |locked|
            lock_status = locked ? "locked" : "skipped"
            logger.log_debug("processor: lock for #{processor_task}: #{lock_status}")

            yield(locked ? processor_task : nil)
          end
        end

        def process(task)
          lock_timer = Cutoff.new(lock_timeout)
          last_id = 0

          box_worker.item_execution_runtime.measure(task.yabeda_labels) do
            Outbox.database_switcher.use_master do
              task.ids.each do |id|
                ProcessItem.call(task.item_class, id, worker_version: task.yabeda_labels[:worker_version])

                box_worker.job_items_counter.increment(task.yabeda_labels)
                last_id = id
                lock_timer.checkpoint!
              end
            end
          end
        rescue Cutoff::CutoffExceededError
          box_worker.job_timeout_counter.increment(task.yabeda_labels)
          logger.log_info("Lock timeout while processing #{task.resource_key} at id #{last_id}")
        end

        def fetch_redis_job(scheduled_task)
          _queue, result = redis.blocking_call(redis_block_timeout, "BRPOP", "#{scheduled_task.item_class.box_name}:job_queue", brpop_delay)
          return if result.blank?

          RedisJob.deserialize!(result)
        rescue => ex
          logger.log_error("error while fetching redis job: #{ex.message}")
        end

        def redis_block_timeout
          redis.read_timeout + brpop_delay
        end
      end
    end
  end
end
