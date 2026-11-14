# frozen_string_literal: true

require "test_helper"

class EventStreamNamingTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
  end

  context ".framework_stream" do
    should "return tenant-namespaced stream name" do
      framework_id = SecureRandom.uuid_v7
      stream = EventStreamNaming.framework_stream(framework_id, tenant: @tenant)

      assert_equal "tenant-#{@tenant.id}/Framework-#{framework_id}", stream
    end

    should "use ActsAsTenant.current_tenant when no tenant given" do
      framework_id = SecureRandom.uuid_v7

      ActsAsTenant.with_tenant(@tenant) do
        stream = EventStreamNaming.framework_stream(framework_id)
        assert_equal "tenant-#{@tenant.id}/Framework-#{framework_id}", stream
      end
    end

    should "raise ArgumentError when no tenant context available" do
      ActsAsTenant.without_tenant do
        assert_raises(ArgumentError) do
          EventStreamNaming.framework_stream(SecureRandom.uuid_v7)
        end
      end
    end
  end

  context ".person_development_stream" do
    should "return tenant-namespaced stream name with person and framework" do
      person_id = SecureRandom.uuid_v7
      framework_id = SecureRandom.uuid_v7
      stream = EventStreamNaming.person_development_stream(person_id, framework_id, tenant: @tenant)

      assert_equal "tenant-#{@tenant.id}/PersonDev-#{person_id}-#{framework_id}", stream
    end

    should "use ActsAsTenant.current_tenant when no tenant given" do
      person_id = SecureRandom.uuid_v7
      framework_id = SecureRandom.uuid_v7

      ActsAsTenant.with_tenant(@tenant) do
        stream = EventStreamNaming.person_development_stream(person_id, framework_id)
        assert_equal "tenant-#{@tenant.id}/PersonDev-#{person_id}-#{framework_id}", stream
      end
    end

    should "raise ArgumentError when no tenant context available" do
      ActsAsTenant.without_tenant do
        assert_raises(ArgumentError) do
          EventStreamNaming.person_development_stream(SecureRandom.uuid_v7, SecureRandom.uuid_v7)
        end
      end
    end
  end

  context ".calibration_session_stream" do
    should "return tenant-namespaced stream name" do
      session_id = SecureRandom.uuid_v7
      stream = EventStreamNaming.calibration_session_stream(session_id, tenant: @tenant)

      assert_equal "tenant-#{@tenant.id}/CalibrationSession-#{session_id}", stream
    end

    should "use ActsAsTenant.current_tenant when no tenant given" do
      session_id = SecureRandom.uuid_v7

      ActsAsTenant.with_tenant(@tenant) do
        stream = EventStreamNaming.calibration_session_stream(session_id)
        assert_equal "tenant-#{@tenant.id}/CalibrationSession-#{session_id}", stream
      end
    end

    should "raise ArgumentError when no tenant context available" do
      ActsAsTenant.without_tenant do
        assert_raises(ArgumentError) do
          EventStreamNaming.calibration_session_stream(SecureRandom.uuid_v7)
        end
      end
    end
  end

  context ".person_stream" do
    should "return tenant-namespaced stream name" do
      person_id = SecureRandom.uuid_v7
      stream = EventStreamNaming.person_stream(person_id, tenant: @tenant)

      assert_equal "tenant-#{@tenant.id}/Person-#{person_id}", stream
    end

    should "use ActsAsTenant.current_tenant when no tenant given" do
      person_id = SecureRandom.uuid_v7

      ActsAsTenant.with_tenant(@tenant) do
        assert_equal "tenant-#{@tenant.id}/Person-#{person_id}", EventStreamNaming.person_stream(person_id)
      end
    end

    should "raise ArgumentError when no tenant context available" do
      ActsAsTenant.without_tenant do
        assert_raises(ArgumentError) do
          EventStreamNaming.person_stream(SecureRandom.uuid_v7)
        end
      end
    end
  end

  context ".org_structure_stream" do
    should "return one tenant-namespaced stream per tenant" do
      assert_equal "tenant-#{@tenant.id}/OrgStructure", EventStreamNaming.org_structure_stream(tenant: @tenant)
    end

    should "use ActsAsTenant.current_tenant when no tenant given" do
      ActsAsTenant.with_tenant(@tenant) do
        assert_equal "tenant-#{@tenant.id}/OrgStructure", EventStreamNaming.org_structure_stream
      end
    end

    should "raise ArgumentError when no tenant context available" do
      ActsAsTenant.without_tenant do
        assert_raises(ArgumentError) { EventStreamNaming.org_structure_stream }
      end
    end
  end

  context ".plan_stream" do
    should "return one tenant-namespaced stream per plan" do
      plan_id = SecureRandom.uuid_v7
      assert_equal "tenant-#{@tenant.id}/Plan-#{plan_id}", EventStreamNaming.plan_stream(plan_id, tenant: @tenant)
    end

    should "raise ArgumentError when no tenant context available" do
      ActsAsTenant.without_tenant do
        assert_raises(ArgumentError) { EventStreamNaming.plan_stream(SecureRandom.uuid_v7) }
      end
    end
  end

  context ".extract_tenant_id" do
    should "extract tenant ID from framework stream name" do
      tenant_id = SecureRandom.uuid_v7
      stream = "tenant-#{tenant_id}/Framework-#{SecureRandom.uuid_v7}"

      assert_equal tenant_id, EventStreamNaming.extract_tenant_id(stream)
    end

    should "extract tenant ID from person development stream name" do
      tenant_id = SecureRandom.uuid_v7
      stream = "tenant-#{tenant_id}/PersonDev-#{SecureRandom.uuid_v7}-#{SecureRandom.uuid_v7}"

      assert_equal tenant_id, EventStreamNaming.extract_tenant_id(stream)
    end

    should "raise ArgumentError for invalid stream format" do
      assert_raises(ArgumentError) do
        EventStreamNaming.extract_tenant_id("invalid-stream-name")
      end
    end
  end
end
