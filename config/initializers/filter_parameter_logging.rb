# frozen_string_literal: true

# Be sure to restart your server when you modify this file.

# Configure parameters to be partially matched (e.g. passw matches password) and filtered from the log file.
# Use this to limit dissemination of sensitive information.
# See the ActiveSupport::ParameterFilter documentation for supported notations and behaviors.
Rails.application.config.filter_parameters += [
  :passw, :email, :secret, :token, :_key, :crypt, :salt, :certificate, :otp, :ssn, :cvv, :cvc,
  # Pay band figures, actual pay, exchange rates and budget lines, by exact key: a symbol matches any key
  # containing it, which would hide pay_band_id
  /\A(?:pay|pay_band|minimum|midpoint|maximum|exchange_rate|rate|budget_line|amount|head_count|file|csv|rows)\z/
]
