# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20261022000001_default_feedback_exchange_kinds_to_all")

class DefaultFeedbackExchangeKindsToAllTest < ActiveSupport::TestCase
  OLD_DEFAULT = %w[peer_feedback manager_feedback observation impact].freeze

  def stored(config)
    tenant = create(:tenant)
    DefaultFeedbackExchangeKindsToAll::TenantRow.where(id: tenant.id).update_all(feedback_exchange_config: config)
    tenant
  end

  def config_of(tenant) = DefaultFeedbackExchangeKindsToAll::TenantRow.find(tenant.id).feedback_exchange_config

  def migrate(direction)
    ActiveRecord::Migration.suppress_messages { DefaultFeedbackExchangeKindsToAll.new.migrate(direction) }
  end

  should "turn an empty import list and the old export default, in any order, into all" do
    defaulted = stored({ "peer_name" => "chip", "import_kinds" => [], "export_kinds" => OLD_DEFAULT })
    shuffled = stored({ "export_kinds" => OLD_DEFAULT.reverse })

    migrate(:up)

    assert_equal({ "peer_name" => "chip", "import_kinds" => %w[all], "export_kinds" => %w[all] }, config_of(defaulted))
    assert_equal({ "export_kinds" => %w[all] }, config_of(shuffled))
    assert defaulted.reload.feedback_exchange_config.imports_kind?("feedback")
  end

  should "treat a null or blank-only import list as the empty list it was read as" do
    null = stored({ "import_kinds" => nil })
    blanks = stored({ "import_kinds" => [ "" ] })

    migrate(:up)

    assert_equal({ "import_kinds" => %w[all] }, config_of(null))
    assert_equal({ "import_kinds" => %w[all] }, config_of(blanks))
  end

  should "keep a list an admin chose" do
    chosen = stored({ "import_kinds" => %w[peer_feedback], "export_kinds" => %w[peer_feedback manager_feedback observation] })
    widened = stored({ "export_kinds" => OLD_DEFAULT + %w[code_review] })

    migrate(:up)

    assert_equal({ "import_kinds" => %w[peer_feedback], "export_kinds" => %w[peer_feedback manager_feedback observation] },
                 config_of(chosen))
    assert_equal({ "export_kinds" => OLD_DEFAULT + %w[code_review] }, config_of(widened))
  end

  should "leave a config that stored no lists alone" do
    untouched = stored({})
    other = stored({ "peer_name" => "chip" })

    migrate(:up)

    assert_equal({}, config_of(untouched))
    assert_equal({ "peer_name" => "chip" }, config_of(other))
  end

  should "do nothing the second time" do
    tenant = stored({ "import_kinds" => [], "export_kinds" => OLD_DEFAULT })
    migrate(:up)

    assert_no_changes -> { DefaultFeedbackExchangeKindsToAll::TenantRow.find(tenant.id).attributes } do
      migrate(:up)
    end
    assert_equal({ "import_kinds" => %w[all], "export_kinds" => %w[all] }, config_of(tenant))
  end

  should "restore the old meaning on the way down" do
    tenant = stored({ "import_kinds" => [], "export_kinds" => OLD_DEFAULT })
    chosen = stored({ "import_kinds" => %w[impact], "export_kinds" => %w[impact] })

    migrate(:up)
    migrate(:down)

    assert_equal({ "import_kinds" => [], "export_kinds" => OLD_DEFAULT }, config_of(tenant))
    assert_equal({ "import_kinds" => %w[impact], "export_kinds" => %w[impact] }, config_of(chosen))
  end
end
