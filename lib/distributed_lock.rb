require 'redis'
require 'redis-lock'

class DistributedLock
  def self.lock(lock_name)
    Redis.current.lock("publishing-api:#{Rails.env}:#{lock_name}", life: 60 * 60, acquire: 0) do
      Rails.logger.debug("Successfully got a lock. Running...")
      yield
    end
  rescue Redis::Lock::LockNotAcquired => e
    Rails.logger.debug("Failed to get lock for #{lock_name} (#{e.message}). Another process probably got there first.")
  end
end
