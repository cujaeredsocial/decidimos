# frozen_string_literal: true

# Mirrors decidim-generators/lib/decidim/generators/app_templates/verifications_initializer.rb (0.31.5).
# Enable it per organization in /system -> "Available authorizations", then
# require it per action in Admin -> component -> Permissions.
Decidim::Verifications.register_workflow(:ci_authorization_handler) do |workflow|
  workflow.form = "CiAuthorizationHandler"
  workflow.renewable = true
end
