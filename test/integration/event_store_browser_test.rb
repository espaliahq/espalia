# frozen_string_literal: true

require "test_helper"

class EventStoreBrowserTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  class NoteWritten < RubyEventStore::Event
    extend Shreddable
    shreddable :note, by: :plan
  end

  setup do
    @tenant = create(:tenant)
    @plan_id = SecureRandom.uuid_v7
    @event = NoteWritten.new(data: { plan_id: @plan_id, note: "Moving to the platform team" })
    store = Rails.configuration.event_store
    ActsAsTenant.with_tenant(@tenant) do
      store.with_metadata(tenant_id: @tenant.id) { store.publish(@event, stream_name: "tenant-#{@tenant.id}/BrowserTest-#{@plan_id}") }
    end
    sign_in create(:user, global_admin: true)
  end

  should "show a shreddable event with its field as a placeholder" do
    get "/res/events/#{@event.event_id}"

    assert_response :success
    assert_includes response.body, "[shreddable]"
    assert_not_includes response.body, "platform team"
    assert_includes response.body, NoteWritten.name
  end
end
