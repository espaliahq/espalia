# frozen_string_literal: true

# Says, on the assessment itself, that feedback is waiting to be placed on a
# capability — it is invisible to every card and score until someone does —
# and points at the hub, where placing happens. Rendered for viewers who see
# all the assessment's evidence (the assessee, the manager side, admins).
class Views::Assessments::UnplacedFeedbackNotice < Views::Base
  # @param count [Integer] unplaced items on this assessment (> 0)
  # @param whose [String] "you" for the assessee, otherwise the assessee's name
  # @param place [String, nil] "org" when the hub lists these items only in
  #   its whole-org view (a skip-level viewer)
  def initialize(count:, whose:, place: nil)
    @count = count
    @whose = whose
    @place = place
  end

  def view_template
    # Static content, not a live region: the page's rating announcements own
    # that role, and a region present at load is never announced anyway.
    render Components::Kit::Alert.new(tone: :warning, role: :region, class: "mb-4",
                                      aria: { label: "Feedback waiting to be placed" },
                                      data: { testid: "unplaced-feedback-notice" }) do
      div(class: "flex flex-wrap items-center justify-between gap-2") do
        p { sentence }
        a(href: evidence_hub_path(place: @place, anchor: "needs-you"),
          class: "inline-flex items-center min-h-11 font-medium hover:underline") do
          @count == 1 ? "Place it →" : "Place them →"
        end
      end
    end
  end

  private

  def sentence
    pieces = @count == 1 ? "1 piece of feedback" : "#{@count} pieces of feedback"
    verb = @count == 1 ? "is" : "are"
    "#{pieces} about #{@whose} #{verb} waiting to be placed on a capability — until then it shows on no card and counts nowhere."
  end
end
