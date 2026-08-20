# frozen_string_literal: true

require "test_helper"

# The expanded-row illustration item. Pins the per-item marker that keeps
# multiple illustrations under one role legible as discrete examples.
class Views::Frameworks::Explorer::IllustrationFrameTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    ActsAsTenant.current_tenant = @tenant
    @illustration = create(:framework_role_illustration, tenant: @tenant)
  end

  teardown { ActsAsTenant.current_tenant = nil }

  # Through a real view context — the frame wraps itself in turbo_frame_tag.
  def view_context
    @view_context ||= ApplicationController.new
      .tap { |controller| controller.request = ActionDispatch::TestRequest.create }
      .view_context
  end

  context "Views::Frameworks::Explorer::IllustrationFrame" do
    should "render an item marker before the description" do
      html = view_context.render(Views::Frameworks::Explorer::IllustrationFrame.new(
        illustration: @illustration, framework_id: SecureRandom.uuid_v7
      ))
      assert_match(/<li[^>]*>.*rounded-full[^>]*aria-hidden="true"/m, html)
      assert_includes html, @illustration.description
    end
  end
end
