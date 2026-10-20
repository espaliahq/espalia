# frozen_string_literal: true

require "test_helper"

class FeedbackExchange::RecordTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    ActsAsTenant.current_tenant = @tenant
    @author = create(:person, tenant: @tenant, email: "a@example.com")
    @recipient = create(:person, tenant: @tenant, email: "r@example.com")
  end

  teardown { ActsAsTenant.current_tenant = nil }

  should "skip an item whose author cannot be named, and keep the others" do
    orphan = build(:evidence_item, tenant: @tenant, author_id: SecureRandom.uuid_v7, person_id: @recipient.id)
    named = create(:evidence_item, tenant: @tenant, author: @author, person_id: @recipient.id)

    records = FeedbackExchange::Record.for([ orphan, named ])

    assert_equal [ named.id ], records.pluck(:id)
  end

  should "name the exchange origin on an item that was itself imported" do
    item = create(:evidence_item, tenant: @tenant, author: @author, person_id: @recipient.id, recorded_via: "feedback_exchange")
    item.update_column(:external_reference, { system: "lattice", external_id: "l-9" })

    record = FeedbackExchange::Record.for([ item.reload ]).sole

    assert_equal({ system: "lattice", id: "l-9" }, record[:external_reference])
  end

  should "leave external_reference null for an ordinary link such as a pull request" do
    item = create(:evidence_item, tenant: @tenant, author: @author, person_id: @recipient.id,
                                  external_reference: { system: "github", url: "https://github.com/o/r/pull/1" })

    assert_nil FeedbackExchange::Record.for([ item ]).sole[:external_reference]
  end
end
