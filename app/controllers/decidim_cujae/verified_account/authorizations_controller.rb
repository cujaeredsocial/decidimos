# frozen_string_literal: true

module DecidimCujae
  module VerifiedAccount
    # Participant side of the :verified_account workflow: explains the two ways
    # to get verified and runs the EnZona OAuth2 round trip.
    # Mirrors Decidim::Verifications::Sms::AuthorizationsController.
    class AuthorizationsController < Decidim::Verifications::ApplicationController
      SESSION_KEY = "verified_account_enzona"

      helper_method :authorization, :enzona_configured?

      before_action :confirmed_user, only: [:enzona, :callback]

      def new
        enforce_permission_to(:create, :authorization, authorization:)
      end

      # Required by Decidim::Verifications::Adapter#resume_authorization_path.
      # This workflow never leaves pending authorizations, so just restart.
      def edit
        redirect_to new_authorization_path(redirect_url:)
      end

      def enzona
        enforce_permission_to(:create, :authorization, authorization:)
        return fail_with(:not_configured) unless enzona_configured?

        state = SecureRandom.urlsafe_base64(32)
        redirect_uri = DecidimCujae::Enzona.redirect_uri(request.base_url)
        # The token exchange must send the same redirect_uri as this request.
        session[SESSION_KEY] = { "state" => state, "redirect_url" => redirect_url, "redirect_uri" => redirect_uri }

        redirect_to DecidimCujae::Enzona.authorize_url(redirect_uri:, state:), allow_other_host: true
      end

      def callback
        enforce_permission_to(:create, :authorization, authorization:)

        stored = session.delete(SESSION_KEY) || {}
        @return_to = stored["redirect_url"]

        return fail_with(:invalid_state) unless valid_state?(stored["state"])
        return fail_with(:cancelled) if params[:error].present? || params[:code].blank?

        redirect_uri = stored["redirect_uri"].presence || DecidimCujae::Enzona.redirect_uri(request.base_url)
        uid = DecidimCujae::Enzona.fetch_uid(params[:code], redirect_uri:)
        return fail_with(:error) if uid.blank?

        # Decidim::Command instance_evals this block: use locals, not ivars.
        return_to = @return_to.presence || decidim_verifications.authorizations_path
        success = t("success", scope: i18n_scope)

        GrantVerification.call(user: current_user, verification_method: "enzona", unique_id: uid) do
          on(:ok) do
            flash[:notice] = success
            redirect_to return_to
          end
          on(:already_used) { fail_with(:already_used) }
          on(:invalid) { fail_with(:error) }
        end
      rescue OAuth2::Error, Faraday::Error => e
        Rails.logger.warn("[EnZona verification] #{e.class}: #{e.message}")
        fail_with(:error)
      end

      private

      def i18n_scope
        "decidim_cujae.verified_account.authorizations"
      end

      def fail_with(reason)
        flash[:alert] = t("errors.#{reason}", scope: i18n_scope)
        redirect_to new_authorization_path(redirect_url: @return_to.presence)
      end

      def valid_state?(expected)
        params[:state].present? && expected.present? &&
          ActiveSupport::SecurityUtils.secure_compare(params[:state].to_s, expected)
      end

      def enzona_configured?
        DecidimCujae::Enzona.configured?
      end

      def authorization
        @authorization ||= Decidim::Authorization.find_or_initialize_by(user: current_user, name: WORKFLOW)
      end
    end
  end
end
