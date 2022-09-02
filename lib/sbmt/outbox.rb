# frozen_string_literal: true

require "ruby2_keywords"
require "rails"
require "sidekiq"
require "sidekiq-unique-jobs"
require "dry-initializer"
require "dry-monads"
require "dry/monads/do"
require "schked"
require "kafka"
require "delivery_boy"
require "waterdrop"
require "yabeda"
require "after_commit_everywhere"
require "exponential_backoff"

require_relative "outbox/version"
require_relative "outbox/errors"
require_relative "outbox/error_tracker"
require_relative "outbox/logger"
require_relative "outbox/kafka_producers/delivery_boy"
require_relative "outbox/kafka_producers/async_producer"
require_relative "outbox/kafka_producers/sync_producer"
require_relative "outbox/engine"

module Sbmt
  module Outbox
    module_function

    def config
      @config ||= Rails.application.config.outbox
    end

    def logger
      @logger ||= Sbmt::Outbox::Logger.new
    end

    def error_tracker
      @error_tracker ||= config.error_tracker.constantize
    end

    def item_classes
      @item_classes ||= config.item_classes.map(&:constantize)
    end

    def dead_letter_classes
      @dead_letter_classes ||= config.dead_letter_classes.map(&:constantize)
    end

    def yaml_config
      @yaml_config ||= config.paths.each_with_object({}.with_indifferent_access) do |path, memo|
        memo.deep_merge!(
          YAML.safe_load(ERB.new(File.read(path)).result, [], [], true)
            .with_indifferent_access
            .fetch(Rails.env, {})
        )
      end
    end
  end
end