# frozen_string_literal: true

require "test_helper"

class FeedbackExchangeImportTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    ActsAsTenant.current_tenant = @tenant
  end

  teardown { ActsAsTenant.current_tenant = nil }

  def row(status, skip_reason = nil, **attributes)
    FeedbackExchangeImport.create!(origin: "chip", external_id: SecureRandom.hex(4), status: status,
                                   skip_reason: skip_reason, synced_at: Time.current, **attributes)
  end

  should "need a skip reason exactly when skipped" do
    assert_not FeedbackExchangeImport.new(origin: "chip", external_id: "1", status: "skipped", synced_at: Time.current).valid?
    assert_not FeedbackExchangeImport.new(origin: "chip", external_id: "1", status: "imported", skip_reason: "echo",
                                          synced_at: Time.current).valid?
  end

  should "count records by outcome and skip reason" do
    row("imported")
    row("imported")
    row("updated")
    row("skipped", "echo")
    row("skipped", "no_assignment")
    row("skipped", "no_assignment")

    assert_equal({ imported: 2, updated: 1, withdrawn: 0, skipped: 3, skip_reasons: { "echo" => 1, "no_assignment" => 2 } },
                 FeedbackExchangeImport.summary)
  end

  should "retry only the skips our side can fix, and only when it kept the record" do
    keep = row("skipped", "no_assignment", record: { "id" => "1" })
    row("skipped", "no_assignment")
    row("skipped", "echo", record: { "id" => "2" })
    assert_equal [ keep ], FeedbackExchangeImport.retriable.to_a
  end

  should "list the people a peer named that GrowthOS could not find, most seen first" do
    row("skipped", "author_unmatched", record: { "author" => { "email" => "Ghost@example.com", "display_name" => "Ghost" } })
    row("skipped", "author_unmatched", record: { "author" => { "email" => "ghost@example.com" } })
    row("skipped", "recipient_unmatched", record: { "recipient" => { "email" => "new@example.com", "display_name" => "New" } })

    assert_equal [
      { email: "ghost@example.com", display_name: "Ghost", role: "author", records: 2 },
      { email: "new@example.com", display_name: "New", role: "recipient", records: 1 }
    ], FeedbackExchangeImport.unmatched_people
  end
end
