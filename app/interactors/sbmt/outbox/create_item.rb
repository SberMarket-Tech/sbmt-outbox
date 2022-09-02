# frozen_string_literal: true

module Sbmt
  module Outbox
    class CreateItem < Outbox::DryInteractor
      param :item_class, reader: :private
      option :attributes, reader: :private

      def call
        record = item_class.new(attributes)

        if record.save
          track_last_stored_id(record.id)

          Success(record)
        else
          Failure(record.errors)
        end
      end

      private

      def track_last_stored_id(item_id)
        after_commit do
          Yabeda
            .outbox
            .last_stored_event_id
            .set(item_class.metric_labels, item_id)
        end
      end
    end
  end
end