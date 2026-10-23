# frozen_string_literal: true

# The session page's update toast: a persistent `role="status"` region that
# `calibration_freshness_controller` fills when a reload brought new numbers
# ("Updated just now · 3 ratings changed since 14:32 — Raj ×2, Sam ×1.
# Readiness 76% → 78%."), or with a standing notice while a reload is held
# for an open drawer — plus the `<template>`s each is cloned from.
#
# The region never leaves the DOM, so assistive tech announces each message
# without stealing focus — the explorer's WriteStatus rule. It sits in the
# flow under the header rather than floating: the comparison drawer owns the
# bottom of the viewport and the header's buttons the top right.
class Views::CalibrationSessions::FreshnessStatus < Views::Base
  REGION_ID = "calibration-freshness-status"

  def view_template
    div(
      id: REGION_ID,
      role: "status",
      aria_live: "polite",
      aria_atomic: "true",
      class: "empty:hidden mt-3",
      data: { calibration_freshness_target: "region" }
    )
    template(data: { calibration_freshness_target: "template" }) { toast }
    template(data: { calibration_freshness_target: "waitingTemplate" }) { waiting_notice }
  end

  private

  # Not a toast: it stays until the held reload lands and replaces it. Both
  # messages land inside the status region, so they don't carry a role of their own.
  def waiting_notice
    render Components::Kit::Alert.new(tone: :warning, role: :none, class: "max-w-2xl", data: { freshness_waiting: "" }) do
      "Newer ratings are waiting — they load when the comparison drawer or dialog closes."
    end
  end

  def toast
    render Components::Kit::Alert.new(dismissible: true, dismiss_after: 12_000, role: :none, class: "max-w-2xl") do
      span(data: { message: "" })
    end
  end
end
