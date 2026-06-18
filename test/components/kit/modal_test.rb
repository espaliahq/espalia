# frozen_string_literal: true

require "test_helper"

class Components::Kit::ModalTest < ActiveSupport::TestCase
  # The body block runs in the CALLER's Phlex context, so these tests assert
  # only the caller-agnostic chrome. Body rendering is exercised by the
  # delegation modal (manager_show_view) and evidence form views.
  def standalone_modal
    Components::Kit::Modal.new(id: "demo-modal", title: "Demo").call do |m|
      m.trigger { "Open" }
      m.body { } # rubocop:disable Lint/EmptyBlock
    end
  end

  context "Components::Kit::Modal (standalone)" do
    should "render its own modal controller and trigger" do
      html = standalone_modal
      assert_includes html, 'data-controller="modal"'
      assert_includes html, 'data-action="modal#open"'
      assert_includes html, "Open"
    end

    should "render the overlay hidden by default with title and close" do
      html = standalone_modal
      assert_includes html, 'id="demo-modal"'
      assert_includes html, 'data-modal-target="overlay"'
      assert_includes html, "hidden"
      assert_includes html, 'data-action="click->modal#close"'
      assert_includes html, "Demo"
    end

    # Outside-click dismissal is opt-in so transactional modals can't be
    # discarded by a stray background click.
    should "not enable outside-click dismissal by default" do
      assert_includes standalone_modal, 'data-modal-dismiss-on-outside-click-value="false"'
    end

    should "enable outside-click dismissal when opted in" do
      html = Components::Kit::Modal.new(id: "demo-modal", title: "Demo",
                                        dismiss_on_outside_click: true).call do |m|
        m.trigger { "Open" }
        m.body { } # rubocop:disable Lint/EmptyBlock
      end
      assert_includes html, 'data-modal-dismiss-on-outside-click-value="true"'
    end
  end

  context "Components::Kit::Modal (embedded)" do
    should "omit its own controller and trigger" do
      html = Components::Kit::Modal.new(id: "embedded", title: "E", standalone: false).call do |m|
        m.body { } # rubocop:disable Lint/EmptyBlock
      end
      assert_not_includes html, 'data-controller="modal"'
      assert_includes html, 'data-modal-target="overlay"'
      assert_includes html, 'id="embedded"'
    end
  end
end
