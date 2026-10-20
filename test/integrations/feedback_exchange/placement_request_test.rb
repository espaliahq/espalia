# frozen_string_literal: true

require "test_helper"

class FeedbackExchange::PlacementRequestTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @tenant = create(:tenant)
    ActsAsTenant.current_tenant = @tenant
    @handler = PersonDevelopment::CommandHandler.new

    @manager = create(:person, tenant: @tenant, name: "Morgan")
    @assessee = create(:person, tenant: @tenant, name: "Alex", manager: @manager)
    @peer = create(:person, tenant: @tenant, name: "Priya")
    @delegate = create(:person, tenant: @tenant, name: "Dana")
    @manager_user = create(:user)
    create(:tenant_user, tenant: @tenant, user: @manager_user, person: @manager)

    @framework_id = SecureRandom.uuid_v7
    @handler.assign_to_framework(@assessee.id, @framework_id, SecureRandom.uuid_v7, SecureRandom.uuid_v7)
    @evidence_id = SecureRandom.uuid_v7
  end

  teardown { ActsAsTenant.current_tenant = nil }

  def import!(author: @peer)
    @handler.record_evidence(@assessee.id, @framework_id, @evidence_id,
      source: "peer", evidence_type: "peer_feedback", content: "Great **incident** call.",
      author_id: author.id, cycle_id: nil, external_reference: { system: "chip", external_id: "c-1" })
    EvidenceItem.find(@evidence_id)
  end

  should "ask the reporting manager to place it, linking to the hub card" do
    item = import!
    perform_enqueued_jobs { assert_equal [ @manager.id ], FeedbackExchange::PlacementRequest.new(item).deliver }

    notification = @manager_user.notifications.reload.sole
    assert_equal "Priya gave Alex feedback in Chip", notification.inbox_title
    assert_equal "Confirm which capabilities it speaks to and what it shows — “Great incident call.”", notification.inbox_body
    assert_equal "/evidence#evidence-item-#{@evidence_id}", notification.inbox_url
  end

  should "ask an active rating delegate too, and never twice" do
    @handler.delegate_manager_rating(@assessee.id, @framework_id, @delegate.id, granted_by_id: @manager.id)
    item = import!

    assert_equal [ @manager.id, @delegate.id ].sort, FeedbackExchange::PlacementRequest.new(item).deliver.sort
    assert_empty FeedbackExchange::PlacementRequest.new(item).deliver
    assert_equal 1, @manager_user.notifications.reload.size
  end

  should "not ask the author about their own feedback" do
    assert_empty FeedbackExchange::PlacementRequest.new(import!(author: @manager)).deliver
  end
end
