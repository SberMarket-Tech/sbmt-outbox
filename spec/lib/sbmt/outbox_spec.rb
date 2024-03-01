# frozen_string_literal: true

describe Sbmt::Outbox do
  describe "batch_process_middlewares" do
    it "returns default middlewares" do
      expect(described_class.batch_process_middlewares).to eq([described_class::Middleware::Sentry::TracingBatchProcessMiddleware])
    end
  end

  describe "item_process_middlewares" do
    it "returns default middlewares" do
      expect(described_class.item_process_middlewares).to eq([described_class::Middleware::Sentry::TracingItemProcessMiddleware])
    end
  end
end
