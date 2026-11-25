# frozen_string_literal: true

namespace :decidim_cujae do
  namespace :verified_account do
    desc "One-off migration (feat/no-enzona): EnZona stops being a sign-in method and becomes a verification"
    task migrate_from_enzona_login: :environment do
      workflow = DecidimCujae::VerifiedAccount::WORKFLOW

      Decidim::Organization.find_each do |organization|
        # 1. Drop the old xetid OmniAuth settings. Otherwise
        #    Organization#enabled_omniauth_providers keeps listing :xetid
        #    (omniauth_settings_xetid_enabled = true) and the sign-in page
        #    renders a button whose route no longer exists.
        settings = (organization.omniauth_settings || {}).reject { |key, _| key.to_s.start_with?("omniauth_settings_xetid_") }
        # 2. Enable the verification workflow (same as ticking it in /system).
        authorizations = (organization.available_authorizations | [workflow])

        # update_columns: only these two columns change, and unrelated org
        # validations (host, locales...) must not block the migration.
        organization.update_columns(omniauth_settings: settings, available_authorizations: authorizations) # rubocop:disable Rails/SkipsModelValidations
        puts "[#{organization.host}] xetid sign-in settings removed, #{workflow} enabled"
      end

      # 3. Everyone who signed in with EnZona already proved who they are:
      #    turn their identity into a granted EnZona verification.
      granted = conflicts = skipped = 0
      Decidim::Identity.where(provider: "xetid").includes(:user).find_each do |identity|
        user = identity.user
        if user.nil? || user.deleted?
          skipped += 1
          next
        end

        DecidimCujae::VerifiedAccount::GrantVerification.call(user:, verification_method: "enzona", unique_id: identity.uid) do
          on(:ok) { granted += 1 }
          on(:already_used) do
            conflicts += 1
            puts "  conflict: EnZona uid already verifies another account (user ##{user.id})"
          end
          on(:invalid) { skipped += 1 }
        end
      end

      puts "EnZona identities -> verifications: #{granted} granted, #{conflicts} conflicts, #{skipped} skipped"
      puts "The xetid identity rows were kept (decidim_identities). They are no longer used to sign in."
    end
  end
end
