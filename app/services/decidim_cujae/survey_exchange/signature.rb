# frozen_string_literal: true

require "openssl"
require "base64"

module DecidimCujae
  module SurveyExchange
    # File integrity signature (spec 5.6): HMAC-SHA256 over the JCS form of
    # the whole file without the `integrity` member.
    #
    # `key_id` is "v1:" + a short HMAC of the signing key, so a file signed by
    # another installation (different secret_key_base) is recognised as
    # foreign and treated as unsigned, while a file signed by this
    # installation with a wrong signature is rejected (SEC6).
    module Signature
      KEY_SALT = "decidim-survey-exchange/signature/v1"
      ALGORITHM = "HMAC-SHA256"
      CANONICALIZATION = "JCS"

      module_function

      def key
        Rails.application.key_generator.generate_key(KEY_SALT, 32)
      end

      def key_id
        "v1:#{OpenSSL::HMAC.hexdigest("SHA256", key, "key-id")[0, 16]}"
      end

      def sign(data)
        payload = data.except("integrity", :integrity)
        {
          "algorithm" => ALGORITHM,
          "canonicalization" => CANONICALIZATION,
          "key_id" => key_id,
          "signature" => digest(payload)
        }
      end

      # Returns :absent, :valid or :foreign. Raises Error for a malformed or
      # invalid signature made with this installation's key.
      def verify!(data)
        integrity = data["integrity"]
        return :absent if integrity.nil?

        unless integrity.is_a?(Hash) && integrity.keys.sort == %w(algorithm canonicalization key_id signature) &&
               integrity["algorithm"] == ALGORITHM && integrity["canonicalization"] == CANONICALIZATION &&
               integrity["key_id"].is_a?(String) && integrity["signature"].is_a?(String)
          raise Error.new(:invalid_signature, ["integrity: malformed"])
        end
        return :foreign unless integrity["key_id"] == key_id

        expected = digest(data.except("integrity"))
        raise Error.new(:invalid_signature, ["integrity.signature does not match"]) unless ActiveSupport::SecurityUtils.secure_compare(expected, integrity["signature"])

        :valid
      end

      def digest(payload)
        canonical = Canonical.jcs(Canonical.json_roundtrip(payload))
        Base64.urlsafe_encode64(OpenSSL::HMAC.digest("SHA256", key, canonical.encode("UTF-8")), padding: false)
      end
    end
  end
end
