# frozen_string_literal: true

module DecidimCujae
  module SurveyExchange
    # JSON canonicalization (RFC 8785 subset: strings, integers, booleans,
    # null, objects and arrays) and normalization helpers (spec 5.3, steps 3-4).
    module Canonical
      module_function

      # JCS: object keys sorted by code point, no whitespace, UTF-8 strings
      # without escaping non-ASCII characters.
      def jcs(value)
        case value
        when Hash
          "{#{value.keys.map(&:to_s).sort.map { |k| "#{JSON.generate(k)}:#{jcs(fetch_key(value, k))}" }.join(",")}}"
        when Array
          "[#{value.map { |v| jcs(v) }.join(",")}]"
        when Float
          raise ArgumentError, "decimal numbers are not allowed in canonical JSON"
        else
          JSON.generate(value)
        end
      end

      # Round trip through JSON so that only pure JSON types remain.
      def json_roundtrip(value)
        JSON.parse(JSON.generate(value))
      end

      # Translated value normalization: drops machine_translations and empty
      # locales; returns nil when nothing is left.
      def translated(value)
        return nil unless value.is_a?(Hash)

        clean = value.each_with_object({}) do |(locale, text), memo|
          next if locale.to_s == "machine_translations"
          next if text.nil? || text == ""

          memo[locale.to_s] = text
        end
        clean.empty? ? nil : clean
      end

      def fetch_key(hash, key)
        hash.has_key?(key) ? hash[key] : hash[key.to_sym]
      end
    end
  end
end
