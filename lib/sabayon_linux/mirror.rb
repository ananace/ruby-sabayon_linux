# frozen_string_literal: true

require 'net/ftp'
require 'net/http'
require 'time'

module SabayonLinux
  class Mirror
    CONNECTION_CHECK_INTERVAL = 4 * 60 * 60 # every four hours
    TIMESTAMP_CHECK_INTERVAL = 30 * 60 # 2/hour
    RATE_CHECK_INTERVAL = 1 * 24 * 60 * 60 # 1/day

    # TIMESTAMP_PATH = 'entropy/TIMESTAMP'
    TIMESTAMP_PATH = 'entropy/standard/sabayonlinux.org/database/amd64/5/packages.db.timestamp'

    attr_accessor :name, :country, :speed, :logger,
                  :ftp_servers, :http_servers, :rsync_servers,
                  :status, :next_check

    def initialize(name:, country:, **params)
      @name = name
      @country = country
      @speed = params[:speed]
      @logger = params[:logger]

      @ftp_servers = params[:ftp_servers]
      @http_servers = params[:http_servers]
      @rsync_servers = params[:rsync_servers]

      @status = params.fetch(:status, :unknown)
      @status = @status.to_sym if @status.is_a? String
      @failed_checks = params.fetch(:failed_checks, 0)

      @timestamp = params[:timestamp]
      @timestamp = Time.at(@timestamp) if @timestamp.is_a? Numeric
      @timestamp = Time.parse(@timestamp) unless @timestamp.nil? || @timestamp.is_a?(Time)

      @last_rate_speed = params[:last_rate_speed]
      @last_rate_speed_source = params[:last_rate_speed_source]
      @last_rate_speed_source = @last_rate_speed_source.to_sym if @last_rate_speed_source.is_a? String

      @next_rate_check = params.fetch(:next_rate_check, Time.at(0))
      @next_rate_check = Time.at(@next_rate_check) if @next_rate_check.is_a? Numeric
      @next_rate_check = Time.parse(@next_rate_check) unless @next_rate_check.is_a? Time

      @next_check = params.fetch(:next_check, Time.at(0))
      @next_check = Time.at(@next_check) if @next_check.is_a? Numeric
      @next_check = Time.parse(@next_check) unless @next_check.is_a? Time

      @next_timestamp_check = params.fetch(:next_timestamp_check, Time.at(0))
      @next_timestamp_check = Time.at(@next_timestamp_check) if @next_timestamp_check.is_a? Numeric
      @next_timestamp_check = Time.parse(@next_timestamp_check) unless @next_timestamp_check.is_a? Time
    end

    def check_connection
      return status if Time.now < next_check
      logger.debug "#{name} - Connection check timeout reached (#{next_check})" if logger

      check_connection!
    end

    def check_connection!
      return :no_servers unless http_servers&.any? || ftp_servers&.any?

      # TODO: Test if https is also available

      attempts = 0

      servers = (http_servers || []) + (ftp_servers || [])
      available = servers.inject(nil) do |timestamp, base_url|
        url = URI(File.join(base_url, TIMESTAMP_PATH))
        ssl = url.scheme == 'https'

        begin
          attempts = attempts + 1
          logger.debug "#{name} - Connection check against #{url}" if logger
          if url.scheme == 'ftp'
            resp = Net::FTP.open(url.host, open_timeout: 1, read_timeout: 2) do |ftp|
              ftp.login rescue nil

              ftp.mtime(url.path).to_i
            end
          else
            resp = Net::HTTP.start(url.host, url.port, use_ssl: ssl, open_timeout: 1, read_timeout: 1) do |http|
              http.request_get(url.path)
            end

            if resp.is_a? Net::HTTPRedirection
              target = URI(resp['location'])
              target.path.gsub!(TIMESTAMP_PATH, '')
              target.path.chomp!('/')

              base_url.replace target.to_s
              redo if attempts <= 3
            end

            resp.value
            timestamp = Time.parse(resp['last-modified']).to_i
            # timestamp ||= resp.body.to_i if resp['content-length'].to_i > 0
          end
        rescue StandardError => e
          logger.error "#{name} - #{e.class} on connection check against #{url}" if logger

          next
        ensure
          attempts = 0
        end

        break timestamp
      end

      curr_status = !available.nil?

      if curr_status
        @failed_checks = 0
        backoff = 0

        @timestamp = available
        @next_timestamp_check = Time.now + TIMESTAMP_CHECK_INTERVAL
      else
        @failed_checks += 1
        if @failed_checks == 1
          # On the first failure, schedule a recheck in half an hour
          backoff = -CONNECTION_CHECK_INTERVAL + 30 * 60
        else
          # On repeated failures, schedule the next check later, up to a 24h interval
          backoff = [@failed_checks - 1, 8].min * 2 * 60 * 60
        end
      end

      @next_check = Time.now + CONNECTION_CHECK_INTERVAL + backoff
      @status = curr_status ? :online : :unreachable
      logger.debug "#{name} - Connection status: #{status}" if logger
      @status
    end

    def test_speed(size: :small)
      return @last_rate_speed if @last_rate_speed_source == size && Time.now < @next_rate_check

      logger.debug "#{name} - Speed test timeout reached (#{@next_rate_check})" if logger

      test_speed! size: size
    end

    def test_speed!(size: :small)
      raise 'No HTTP/FTP servers listed' unless http_servers&.any? || ftp_servers&.any?
      raise 'Only sizes :small, :medium, and :large available' unless %i[small medium large].include? size

      @last_rate_speed_source = size
      files = {
        small: 'entropy/MIRROR_TEST', # 1000KiB
        medium: 'entropy/standard/portage/database/amd64/5/packages.db.light', # ~36MiB
        large: 'iso/daily/Sabayon_Linux_DAILY_amd64_tarball.tar.gz', # ~1GiB
      }
      file = files[size] || files[:small]

      servers = (http_servers || []) + (ftp_servers || [])
      speeds = servers.map do |base_url|
        uri = URI(File.join(base_url, file))
        ssl = uri.scheme == 'https'

        logger.debug "#{name} - Testing speed against #{uri}" if logger

        begin
          # pre = Time.now
          start = nil
          if uri.scheme == 'ftp'
            data = Net::FTP.open(uri.host, open_timeout: 2, read_timeout: 10) do |ff|
              ff.login rescue nil

              start = Time.now
              ff.getbinaryfile(uri.path, nil).size
            end
          else
            data = Net::HTTP.start(uri.host, uri.port, use_ssl: ssl, open_timeout: 2, read_timeout: 10) do |http|
              start = Time.now
              resp = http.get(uri.path)
              resp.body.size
            end
          end
          # conn_diff = start - pre
          diff = Time.now - start

          # TODO: Assert retrieved size
          # TODO: Track data rate and connection delay per server

          data / diff
        rescue StandardError => e
          logger.error "#{name} - #{e.class} on speed test against #{uri}" if logger

          next
        end
      end.compact

      if speeds.any?
        speed = speeds.max / 1000 / 1000 * 8

        logger.debug "#{name} - Max speed estimated at #{speed.round(2)} Mbit" if logger
        @status = :online
      else
        logger.debug "#{name} - Failed to test speed" if logger
        @status = :unreachable
      end

      @next_rate_check = Time.now + RATE_CHECK_INTERVAL
      @last_rate_speed = speed
    end

    def timestamp
      return Time.at(@timestamp) if @timestamp && Time.now < @next_timestamp_check

      logger.debug "#{name} - Timestamp check timeout reached (#{@next_timestamp_check})" if logger

      timestamp!
    end

    def timestamp!
      raise 'No HTTP/FTP servers listed' unless http_servers&.any? || ftp_servers&.any?

      servers = (http_servers || []) + (ftp_servers || [])
      @timestamp = servers.inject(nil) do |timestamp, base_url|
        url = URI(File.join(base_url, TIMESTAMP_PATH))
        ssl = url.scheme == 'https'

        logger.debug "#{name} - Checking timestamp from #{url}" if logger

        begin
          if url.scheme == 'ftp'
            timestamp = Net::FTP.open(url.host, open_timeout: 1, read_timeout: 2) do |ftp|
              ftp.login rescue nil

              ftp.mtime(url.path).to_i
            end
          else
            resp = Net::HTTP.start(url.host, url.port, use_ssl: ssl, open_timeout: 1, read_timeout: 1) do |http|
              http.request_get(url.path)
            end

            resp.value
            timestamp = Time.parse(resp['last-modified']).to_i
            # timestamp ||= resp.body.to_i if resp['content-length'].to_i > 0
          end
        rescue StandardError => e
          logger.error "#{name} - #{e.class}: #{e} on timestamp check against #{url}" if logger

          next
        end
        logger.debug "#{name} - Timestamp retrieved as #{Time.at(timestamp)}" if logger

        break timestamp
      end

      logger.debug "#{name} - Failed to get timestamp" if logger && @timestamp.nil?

      @next_timestamp_check = Time.now + TIMESTAMP_CHECK_INTERVAL
      Time.at(@timestamp) if @timestamp
    end

    def available?
      check_connection == :online
    rescue StandardError
      false
    end

    def ftp_servers?
      ftp_servers&.any?
    end

    def http_servers?
      http_servers&.any?
    end

    def https_servers
      http_servers&.select { |u| u.start_with? 'https://' }
    end

    def https_servers?
      https_servers&.any?
    end

    def rsync_servers?
      rsync_servers&.any?
    end

    def to_json(*params)
      {
        name: name,
        country: country,
        speed: speed,

        ftp_servers: ftp_servers,
        http_servers: http_servers,
        rsync_servers: rsync_servers,

        status: status,
        failed_checks: @failed_checks,
        timestamp: @timestamp,

        last_rate_speed: @last_rate_speed,
        last_rate_speed_source: @last_rate_speed_source,
        next_rate_check: @next_rate_check.to_i,

        next_check: next_check.to_i,
        next_timestamp_check: @next_timestamp_check.to_i
      }.compact.to_json(*params)
    end
  end
end
