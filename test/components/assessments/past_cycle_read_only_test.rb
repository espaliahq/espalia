# frozen_string_literal: true

require "test_helper"

# On a past cycle's page nobody edits, relinks, withdraws or deletes, even
# their own feedback and comments (https://github.com/mr-yum/growth-os/issues/669).
class Views::Assessments::PastCycleReadOnlyTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    ActsAsTenant.current_tenant = @tenant
    @author = create(:person, tenant: @tenant)
    @item = create(:evidence_item, tenant: @tenant, author_id: @author.id)
    @comment = create(:person_development_comment, tenant: @tenant, author_id: @author.id,
                                                   capability_stable_id: @item.capability_stable_id,
                                                   level_ordinal: @item.level_ordinal)
  end

  teardown { ActsAsTenant.current_tenant = nil }

  def view_context
    @view_context ||= ApplicationController.new.tap do |controller|
      controller.request = ActionDispatch::TestRequest.create
    end.view_context
  end

  def render(component) = Nokogiri::HTML5.fragment(view_context.render(component))

  def evidence_list(read_only:)
    render(Views::Assessments::Evidence::List.new(
      items: [ @item ], assessment_id: SecureRandom.uuid_v7, viewer_person_id: @author.id, can_create: false,
      capability_stable_id: @item.capability_stable_id, level_ordinal: @item.level_ordinal,
      can_relink_others: true, read_only: read_only
    ))
  end

  def comment_thread(read_only:)
    render(Views::Assessments::Comments::Thread.new(
      comments: [ @comment ], assessment_id: SecureRandom.uuid_v7, viewer_person_id: @author.id, can_create: false,
      capability_stable_id: @item.capability_stable_id, level_ordinal: @item.level_ordinal, tenant_admin: true,
      read_only: read_only
    ))
  end

  should "offer the author the evidence actions on the open cycle, and none on a past one" do
    assert evidence_list(read_only: false).at_css("[aria-label^='Actions for']")
    assert_nil evidence_list(read_only: true).at_css("[aria-label^='Actions for']")
  end

  should "offer the author the comment actions on the open cycle, and none on a past one" do
    assert comment_thread(read_only: false).at_css("[aria-label='Comment actions']")
    assert_nil comment_thread(read_only: true).at_css("[aria-label='Comment actions']")
  end
end
