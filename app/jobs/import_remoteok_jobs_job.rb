class ImportRemoteokJobsJob < ApplicationJob
  queue_as :default

  def perform(*tags)
    ScoutApm::Transaction.ignore! if rand > (ENV["SCOUT_SAMPLE_RATE"] || 1).to_f
    @count = 0
    @jobs = []

    fetch_jobs(tags)

    user = User.codefund_bot
    organization = Organization.codefund

    @jobs.each do |job|
      next if job["legal"].present?

      posting = JobPosting.remoteok.where(source_identifier: job["id"]).first_or_initialize

      posting.user             = user
      posting.organization     = organization
      posting.company_name     = job["company"]
      posting.company_logo_url = job["company_logo"]
      posting.job_type         = ENUMS::JOB_TYPES::FULL_TIME
      posting.title            = job["position"]
      posting.description      = job["description"]
      posting.keywords         = normalize_keywords(job["tags"])
      posting.remote           = true
      posting.url              = job["url"]
      posting.start_date       = Time.at(job["epoch"].to_i).to_date
      posting.end_date         = posting.start_date + 60.days
      posting.status           = posting.start_date >= 60.days.ago ? ENUMS::JOB_STATUSES::ACTIVE : ENUMS::JOB_STATUSES::ARCHIVED
      posting.source           = ENUMS::JOB_SOURCES::REMOTEOK
      posting.auto_renew       = false
      print "#{@count += 1},"
      unless posting.save
        puts "Unable to save: #{posting.errors.inspect}"
      end
    end

    nil
  end

  def fetch_jobs(tags)
    hydra = Typhoeus::Hydra.new(max_concurrency: 10)

    tags.each do |tag|
      request = Typhoeus::Request.new("https://remoteok.io/api?tags=#{tag}")
      request.on_complete do |response|
        JSON.parse(response.body).each { |listing| @jobs << listing.merge({tag: tag}) }
      end
      hydra.queue(request)
    end

    hydra.run
  end

  def normalize_keywords(tags)
    keywords = []

    tags.each do |tag|
      ENUMS::KEYWORDS.keys.each do |key|
        if ENUMS::KEYWORDS[key].include?(tag)
          keywords << key
        end
      end
    end

    if keywords.empty?
      Rails.logger.info("Unmatched tags from remoteok: #{tags.join(", ")}")
      keywords << "Other"
    end

    keywords.uniq.compact.sort
  end
end
