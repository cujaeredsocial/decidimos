# frozen_string_literal: true

module DecidimCujae
  module VerifiedAccount
    # True when the organization offers the "verified_account" workflow and the
    # user has not been granted it yet. Drives the "Verify your account" calls
    # to action (header account menu and My account pages).
    class PendingVerification
      def self.for?(user)
        return false unless user
        return false unless user.organization.available_authorizations.include?(WORKFLOW)

        !Decidim::Authorization.where(user:, name: WORKFLOW).where.not(granted_at: nil).exists?
      end
    end
  end
end
