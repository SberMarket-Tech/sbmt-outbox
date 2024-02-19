# frozen_string_literal: true

require "rails/engine"

module Sbmt
  module Outbox
    class Engine < Rails::Engine
      isolate_namespace Sbmt::Outbox

      config.outbox = ActiveSupport::OrderedOptions.new.tap do |c|
        c.active_record_base_class = "ApplicationRecord"
        c.active_job_base_class = "ApplicationJob"
        c.error_tracker = "Sbmt::Outbox::ErrorTracker"
        c.outbox_item_classes = []
        c.inbox_item_classes = []
        c.paths = []
        c.redis = {url: ENV.fetch("REDIS_URL", "redis://127.0.0.1:6379")}
        c.process_items = ActiveSupport::OrderedOptions.new.tap do |c|
          c.general_timeout = 120
          c.cutoff_timeout = 60
          c.batch_size = 200
        end
        c.worker = ActiveSupport::OrderedOptions.new.tap do |c|
          c.rate_limit = 20
          c.rate_interval = 60
          c.shuffle_jobs = true
        end

        # worker v2
        c.poller = ActiveSupport::OrderedOptions.new.tap do |pc|
          pc.concurrency = 6
          pc.threads_count = 1
          pc.general_timeout = 60
          pc.regular_items_batch_size = 200
          pc.retryable_items_batch_size = 100
        end

        c.database_switcher = "Sbmt::Outbox::DatabaseSwitcher"
        c.batch_process_middlewares = []
        c.item_process_middlewares = []
        c.create_item_middlewares = []

        if defined?(::Sentry)
          c.batch_process_middlewares.push("Sbmt::Outbox::Middleware::Sentry::TracingBatchProcessMiddleware")
          c.item_process_middlewares.push("Sbmt::Outbox::Middleware::Sentry::TracingItemProcessMiddleware")
        end
      end

      rake_tasks do
        load "sbmt/outbox/tasks/retry_failed_items.rake"
        load "sbmt/outbox/tasks/delete_failed_items.rake"
      end
    end
  end
end
