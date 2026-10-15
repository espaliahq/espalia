# frozen_string_literal: true

require "test_helper"

class FeedbackDraftTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
  end

  def build_draft(**attrs)
    ActsAsTenant.with_tenant(@tenant) do
      FeedbackDraft.create!({ tenant: @tenant, author_email: "Nia@Example.com ", content: "Great call.",
                              evidence_type: "peer_feedback" }.merge(attrs))
    end
  end

  should "mint a token, normalise the email and expire after the TTL" do
    draft = build_draft
    assert draft.token.present?
    assert_equal "nia@example.com", draft.author_email
    assert_in_delta FeedbackDraft::TTL.from_now, draft.expires_at, 5.seconds
    assert_equal "/evidence/drafts/#{draft.token}", draft.path
  end

  should "open only for its author, only while unconsumed and unexpired" do
    draft = build_draft
    ActsAsTenant.with_tenant(@tenant) do
      assert_equal draft, FeedbackDraft.open_for(token: draft.token, email: "NIA@example.com")
      assert_nil FeedbackDraft.open_for(token: draft.token, email: "someone@example.com")
      assert_nil FeedbackDraft.open_for(token: "nope", email: "nia@example.com")

      draft.consume!
      assert_nil FeedbackDraft.open_for(token: draft.token, email: "nia@example.com")

      stale = build_draft(expires_at: 1.minute.ago)
      assert_nil FeedbackDraft.open_for(token: stale.token, email: "nia@example.com")
    end
  end
end
