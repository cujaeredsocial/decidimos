# frozen_string_literal: true

# Verifies a participant with their Cuban identity card number (Carné de
# Identidad, CI).
#
# Mirrors decidim-generators/lib/decidim/generators/app_templates/dummy_authorization_handler.rb
# (Decidim 0.31.5). Registered in config/initializers/verifications.rb.
#
# A CI has 11 digits: AAMMDD (birth date) + 5 digits. The 7th digit gives the
# century: 9 => 1800s, 0-5 => 1900s, 6-8 => 2000s.
#
# Privacy: the CI is never stored in clear text. `unique_id` is an HMAC of the
# normalized number, so Decidim can still block the same CI on two accounts
# (Decidim::AuthorizationHandler#duplicate) without keeping the number.
# The key derives from SECRET_KEY_BASE: if it changes, existing authorizations
# no longer match new ones. Back it up.
#
# Declaring a CI does not prove it belongs to the person. Use this handler for
# low-risk actions, or through admin impersonation, where a facilitator sees
# the physical card.
class CiAuthorizationHandler < Decidim::AuthorizationHandler
  CI_LENGTH = 11

  attribute :document_number, String

  validates :document_number, presence: true
  validate :valid_document_number

  def unique_id
    return if normalized_document_number.blank?

    self.class.digest(normalized_document_number)
  end

  # Only non-identifying data. Used by Permissions options in the future
  # (e.g. minimum age), never the CI itself.
  def metadata
    super.merge(birth_year: birth_date&.year)
  end

  # Public so other workflows (e.g. Enzona) can produce the same unique_id
  # for the same CI.
  def self.digest(number)
    key = Rails.application.key_generator.generate_key("ci_authorization_handler", 32)
    OpenSSL::HMAC.hexdigest("SHA256", key, number)
  end

  def self.normalize(number)
    number.to_s.gsub(/\D/, "")
  end

  private

  def normalized_document_number
    @normalized_document_number ||= self.class.normalize(document_number)
  end

  def valid_document_number
    return if document_number.blank?

    errors.add(:document_number, :invalid) unless normalized_document_number.length == CI_LENGTH && birth_date
  end

  def birth_date
    number = normalized_document_number
    return unless number.length == CI_LENGTH

    century = case number[6].to_i
              when 9 then 1800
              when 0..5 then 1900
              else 2000
              end
    date = Date.new(century + number[0, 2].to_i, number[2, 2].to_i, number[4, 2].to_i)
    date unless date > Date.current
  rescue Date::Error
    nil
  end
end
