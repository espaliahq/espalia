# frozen_string_literal: true

require "test_helper"

class Frameworks::PublishedVersionsTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    @framework_id = SecureRandom.uuid_v7
    @person = ActsAsTenant.with_tenant(@tenant) { create(:person, tenant: @tenant) }
  end

  def publish(version, published_by:, actor_id: nil)
    ActsAsTenant.with_tenant(@tenant) do
      Rails.configuration.event_store.append(
        Frameworks::Events::FrameworkVersionPublished.new(
          data: { framework_id: @framework_id, version: version, published_by: published_by },
          metadata: { tenant_id: @tenant.id, actor_id: actor_id }.compact
        ),
        stream_name: EventStreamNaming.framework_stream(@framework_id)
      )
    end
  end

  def versions
    ActsAsTenant.with_tenant(@tenant) { Frameworks::PublishedVersions.new(framework_id: @framework_id).call }
  end

  should "list versions newest first, by their publisher" do
    publish(1, published_by: @person.id)
    publish(2, published_by: @person.id)

    assert_equal [ 2, 1 ], versions.map(&:version)
    assert_equal [ @person.id ], versions.map(&:published_by_id).uniq
  end

  should "fall back to the metadata actor when the publisher is a placeholder, and to nil without one" do
    publish(1, published_by: "seed", actor_id: @person.id)
    publish(2, published_by: "bench")

    by_version = versions.index_by(&:version)
    assert_equal @person.id, by_version[1].published_by_id
    assert_nil by_version[2].published_by_id
  end
end
