# frozen_string_literal: true

# The currencies a pay band or an exchange rate may name, read one way.
module Currency
  # ISO 4217's circulating currencies as of 2026. Its fund, metal and test codes
  # are left out, as nobody is paid in them. Add a code when ISO issues one.
  CODES = %w[
    AED AFN ALL AMD AOA ARS AUD AWG AZN BAM BBD BDT BHD BIF BMD BND BOB BRL BSD BTN BWP BYN BZD
    CAD CDF CHF CLP CNY COP CRC CUP CVE CZK DJF DKK DOP DZD EGP ERN ETB EUR FJD FKP GBP GEL GHS
    GIP GMD GNF GTQ GYD HKD HNL HTG HUF IDR ILS INR IQD IRR ISK JMD JOD JPY KES KGS KHR KMF KPW
    KRW KWD KYD KZT LAK LBP LKR LRD LSL LYD MAD MDL MGA MKD MMK MNT MOP MRU MUR MVR MWK MXN MYR
    MZN NAD NGN NIO NOK NPR NZD OMR PAB PEN PGK PHP PKR PLN PYG QAR RON RSD RUB RWF SAR SBD SCR
    SDG SEK SGD SHP SLE SOS SRD SSP STN SVC SYP SZL THB TJS TMT TND TOP TRY TTD TWD TZS UAH UGX
    USD UYU UZS VED VES VND VUV WST XAF XCD XCG XOF XPF YER ZAR ZMW ZWG
  ].to_set.freeze

  INVALID = "must be an ISO 4217 currency code, such as AUD"

  # Trims and upper-cases a typed code, so " aud " reads as AUD.
  NORMALIZE = ->(code) { code.to_s.strip.upcase }
end
