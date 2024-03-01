# frozen_string_literal: true

require "redlock"
require "sbmt/outbox/v2/box_processor"
require "sbmt/outbox/v2/redis_job"
require "sbmt/outbox/v2/poll_throttler"
require "sbmt/outbox/v2/tasks/poll"

module Sbmt
  module Outbox
    module V2
      class Poller < BoxProcessor
        delegate :poller_config, :logger, to: "Sbmt::Outbox"
        delegate :box_worker, to: "Yabeda"
        attr_reader :partitions_count, :lock_timeout, :regular_items_batch_size, :retryable_items_batch_size, :max_buffer_size, :max_batch_size, :throttler

        def initialize(
          boxes,
          partitions_count: nil,
          threads_count: nil,
          lock_timeout: nil,
          regular_items_batch_size: nil,
          retryable_items_batch_size: nil,
          throttler_tactic: nil,
          redis: nil
        )
          @partitions_count = partitions_count || poller_config.concurrency
          @lock_timeout = lock_timeout || poller_config.general_timeout

          @regular_items_batch_size = regular_items_batch_size || poller_config.regular_items_batch_size
          @retryable_items_batch_size = retryable_items_batch_size || poller_config.retryable_items_batch_size
          @max_buffer_size = @regular_items_batch_size + @retryable_items_batch_size
          @max_batch_size = @regular_items_batch_size

          super(boxes: boxes, threads_count: threads_count || poller_config.threads_count, name: "poller", redis: redis)

          @throttler = PollThrottler.build(throttler_tactic || poller_config.tactic || "default", self.redis, poller_config)
        end

        def throttle(worker_number, poll_task, result)
          throttler.call(worker_number, poll_task, result)
        end

        def process_task(_worker_number, task)
          poll(task)
        end

        private

        def build_task_queue(boxes)
          scheduled_tasks = boxes.map do |item_class|
            schedule_concurrency = (0...partitions_count).to_a
            schedule_concurrency.map do |partition|
              buckets = item_class.calc_bucket_partitions(partitions_count).fetch(partition)

              Tasks::Poll.new(
                item_class: item_class,
                worker_name: worker_name,
                partition: partition,
                buckets: buckets
              )
            end
          end.flatten

          scheduled_tasks.shuffle!
          Queue.new.tap { |queue| scheduled_tasks.each { |task| queue << task } }
        end

        def lock_task(poll_task)
          lock_manager.lock("#{poll_task.resource_path}:lock", lock_timeout * 1000) do |locked|
            lock_status = locked ? "locked" : "skipped"
            logger.log_debug("poller: lock for #{poll_task}: #{lock_status}")

            yield(locked ? poll_task : nil)
          end
        end

        def poll(task)
          lock_timer = Cutoff.new(lock_timeout)
          last_id = 0

          box_worker.item_execution_runtime.measure(task.yabeda_labels) do
            Outbox.database_switcher.use_slave do
              result = fetch_items(task) do |item|
                last_id = item.id
                lock_timer.checkpoint!
              end

              logger.log_debug("poll task #{task}: fetched buckets:#{result.keys.count}, items:#{result.values.sum(0) { |ids| ids.count }}")

              push_to_redis(task, result) if result.present?
            end
          end
        rescue Cutoff::CutoffExceededError
          box_worker.job_timeout_counter.increment(labels)
          logger.log_info("Lock timeout while processing #{task.resource_key} at id #{last_id}")
        end

        def fetch_items(task)
          scope = task.item_class
            .for_processing
            .where(bucket: task.buckets)
            .select(:id, :bucket, :processed_at)

          regular_count = 0
          retryable_count = 0

          # single buffer to preserve item's positions
          poll_buffer = {}

          scope.find_in_batches(batch_size: max_batch_size) do |batch|
            batch.each do |item|
              if item.processed_at
                # skip if retryable buffer capacity limit reached
                next if retryable_count >= retryable_items_batch_size

                poll_buffer[item.bucket] ||= []
                poll_buffer[item.bucket] << item.id

                retryable_count += 1
              else
                poll_buffer[item.bucket] ||= []
                poll_buffer[item.bucket] << item.id

                regular_count += 1
              end

              box_worker.job_items_counter.increment(task.yabeda_labels)

              yield(item)

              # regular items have priority over retryable ones
              break if regular_count >= regular_items_batch_size
            end

            box_worker.batches_per_poll_counter.increment(task.yabeda_labels)

            break if poll_buffer.size >= max_buffer_size || regular_count >= regular_items_batch_size
          end

          poll_buffer
        end

        def push_to_redis(poll_task, ids_per_bucket)
          redis.pipelined do |conn|
            ids_per_bucket.each do |bucket, ids|
              redis_job = RedisJob.new(bucket, ids)

              logger.log_debug("pushing job to redis, items count: #{ids.count}: #{redis_job}")
              conn.call("LPUSH", poll_task.redis_queue, redis_job.serialize)
            end
          end
        end
      end
    end
  end
end
