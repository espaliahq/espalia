# frozen_string_literal: true

require "test_helper"

class Frameworks::ActivityControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @tenant = create(:tenant)
    @admin_user = create(:user, password: "password123")
    @outsider_user = create(:user, password: "password123")

    ActsAsTenant.with_tenant(@tenant) do
      @admin_person = create(:person, tenant: @tenant, email: @admin_user.email)
      create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin, person: @admin_person)

      handler = Frameworks::CommandHandler.new
      @framework_id = SecureRandom.uuid_v7
      rfid = SecureRandom.uuid_v7
      rid = SecureRandom.uuid_v7
      @cat_id = SecureRandom.uuid_v7
      @cap_id = SecureRandom.uuid_v7

      handler.create_framework(@framework_id, "Test Framework")
      handler.add_role_family(@framework_id, rfid, "Engineering")
      handler.add_role(@framework_id, rid, rfid, "Software Engineer", "E", "ic")
      handler.add_level(@framework_id, SecureRandom.uuid_v7, rid, 1, "E1", "E1")
      handler.add_capability_category(@framework_id, @cat_id, "Thinking", ordinal: 1)
      handler.add_capability(@framework_id, @cap_id, SecureRandom.uuid_v7, @cat_id, "Strategic Thinking")
      handler.create_capability_role_binding(@framework_id, SecureRandom.uuid_v7, @cap_id, rid)
      handler.publish_version(@framework_id, "v1")
      handler.add_collaborator(@framework_id, @admin_person.id.to_s, "owner", added_by: @admin_person.id.to_s)
      handler.suggest_edit(@framework_id, SecureRandom.uuid_v7,
        "capability", @cap_id, "description",
        "Sharper wording", @admin_person.id.to_s, mode: :suggesting)
    end
  end

  context "as an owner collaborator" do
    should "render the activity panel with suggestion and structural entries" do
      sign_in @admin_user
      get framework_activity_path(@framework_id, layout: "panel")

      assert_response :success
      assert_select "turbo-frame#suggestion-panel"
      assert_select "[data-controller='framework-activity']"
      assert_match "All framework activity", response.body
      assert_match "Sharper wording", response.body
      assert_match "Added a capability", response.body
    end

    should "give a pending deletion the same inline approve/reject as an edit (no muted Review link)" do
      delete_sid = SecureRandom.uuid_v7
      ActsAsTenant.with_tenant(@tenant) do
        Frameworks::CommandHandler.new.suggest_delete(
          @framework_id, delete_sid, "capability", @cap_id,
          author_id: @admin_person.id.to_s, rationale: "Redundant", mode: :suggesting)
      end

      sign_in @admin_user
      get framework_activity_path(@framework_id, layout: "panel")

      assert_response :success
      assert_match "Proposed archiving", response.body
      # The deletion proposal carries the prominent inline approve control…
      assert_select(
        "[data-controller='suggestion-action'][data-suggestion-action-approve-url-value*='#{delete_sid}']"
      )
      # …and no entry falls back to the muted detail-page "Review" link.
      assert_select "a", { text: "Review", count: 0 }
    end

    should "narrow to a capability under capability focus" do
      sign_in @admin_user
      get framework_activity_path(@framework_id, layout: "panel",
        focus: "capability", capability_id: @cap_id)

      assert_response :success
      assert_match "Strategic Thinking", response.body
    end
  end

  context "suggestion focus (the pane card)" do
    setup do
      @suggestion_id = SecureRandom.uuid_v7
      ActsAsTenant.with_tenant(@tenant) do
        handler = Frameworks::CommandHandler.new
        handler.suggest_edit(@framework_id, @suggestion_id,
          "capability", @cap_id, "description",
          "Weighs long-term impact", @admin_person.id.to_s, mode: :suggesting)
        @comment_id = SecureRandom.uuid_v7
        handler.comment_on_suggestion(@framework_id, @suggestion_id, @comment_id,
          body: "Is this the right frame?", author_id: @admin_person.id.to_s)
        handler.comment_on_suggestion(@framework_id, @suggestion_id, SecureRandom.uuid_v7,
          body: "I believe so", author_id: @admin_person.id.to_s, parent_id: @comment_id)
      end
    end

    should "render the suggestion card with proposal, actions, thread, and composer" do
      sign_in @admin_user
      get framework_activity_path(@framework_id, layout: "panel",
                                  focus: "suggestion", suggestion_id: @suggestion_id)

      assert_response :success
      assert_select "turbo-frame#suggestion-panel"
      assert_match "Weighs long-term impact", response.body
      assert_match "Back to activity", response.body
      # Pending + owner authority -> inline approve; the discussion thread and
      # its composer render; the reply carries the one-level indent.
      assert_match "Approve", response.body
      assert_match "Is this the right frame?", response.body
      assert_match "I believe so", response.body
      assert_select "li.pl-5", minimum: 1
      assert_select "textarea[name='comment[body]']"
    end

    should "fall back to the feed for an unknown suggestion" do
      sign_in @admin_user
      get framework_activity_path(@framework_id, layout: "panel",
                                  focus: "suggestion", suggestion_id: SecureRandom.uuid_v7)

      assert_redirected_to framework_activity_path(@framework_id, layout: "panel")
    end

    should "advertise the discussion on the feed entry" do
      sign_in @admin_user
      get framework_activity_path(@framework_id, layout: "panel")

      assert_response :success
      # Two active comments on the suggestion -> count + latest excerpt chip.
      assert_match "2 · I believe so", response.body
    end
  end

  context "load older (pagination)" do
    setup do
      cap = Frameworks::ActivityFeedQuery::STREAM_READ_LIMIT
      events = Array.new(cap + 5) do |i|
        Frameworks::Events::CapabilityAdded.new(
          data: { framework_id: @framework_id, capability_id: SecureRandom.uuid_v7, name: "bulk-#{i}" },
          metadata: { tenant_id: @tenant.id }
        )
      end
      ActsAsTenant.with_tenant(@tenant) do
        Rails.configuration.event_store.append(events, stream_name: EventStreamNaming.framework_stream(@framework_id))
      end
      sign_in @admin_user
    end

    should "render a load-older affordance when the stream exceeds the read cap" do
      get framework_activity_path(@framework_id, layout: "panel")

      assert_response :success
      assert_select "#framework-activity-list"
      assert_select "#framework-activity-load-more [data-controller='activity-more']"
      assert_match "Load older activity", response.body
    end

    should "append the older batch and swap the footer for a Turbo Stream request" do
      newest = ActsAsTenant.with_tenant(@tenant) do
        Rails.configuration.event_store.read
          .stream(EventStreamNaming.framework_stream(@framework_id)).backward.limit(1).first.event_id
      end

      get framework_activity_path(@framework_id, before: newest),
        headers: { "Accept" => "text/vnd.turbo-stream.html" }

      assert_response :success
      assert_match(/<turbo-stream action="append" target="framework-activity-list">/, response.body)
      assert_match(/<turbo-stream action="replace" target="framework-activity-load-more">/, response.body)
      assert_match(/<turbo-stream action="replace" target="framework-activity-count">/, response.body)
    end
  end

  context "as a non-member" do
    should "deny access" do
      sign_in @outsider_user
      get framework_activity_path(@framework_id, layout: "panel")

      assert_redirected_to root_path
      assert_equal "You are not authorized to perform this action.", flash[:alert]
    end
  end
end
