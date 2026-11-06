namespace :mdm do
  desc "Prune dashboard replay events older than seven days"
  task prune_events: :environment do
    DashboardEvent.where("created_at < ?", 7.days.ago).in_batches.delete_all
  end
end
