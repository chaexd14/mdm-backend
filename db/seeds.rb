# One administrator for the initial dashboard. Re-running seeds preserves an existing password.
AdminAccount.find_or_create_by!(username: 'admin.saiko') do |account|
  account.password = ENV.fetch('MDM_SEED_ADMIN_PASSWORD', '123456')
end
