# frozen_string_literal: true

require 'net/http'
require 'time'

module SabayonLinux
  class Mirror
    CONNECTION_CHECK_INTERVAL = 8 * 60 * 60 # every eight hours
    TIMESTAMP_CHECK_INTERVAL = 30 * 60 # 2/hour

    attr_accessor :name, :country, :speed,
                  :ftp_servers, :http_servers, :rsync_servers,
                  :status, :last_check, :next_check

    def initialize(name:, country:, **params)
      @name = name
      @country = country
      @speed = params[:speed]

      @ftp_servers = params[:ftp_servers]
      @http_servers = params[:http_servers]
      @rsync_servers = params[:rsync_servers]

      @status = params.fetch(:status, :unknown)
      @failed_checks = params.fetch(:failed_checks, 0)
      @last_check = params.fetch(:last_check, Time.at(0))
      @last_check = Time.at(@last_check) if @last_check.is_a? Numeric
      @last_check = Time.parse(@last_check) unless @last_check.is_a? Time
      @next_check = params.fetch(:next_check, Time.now)
      @next_check = Time.at(@next_check) if @next_check.is_a? Numeric
      @next_check = Time.parse(@next_check) unless @next_check.is_a? Time
      @next_timestamp_check = params.fetch(:next_timestamp_check, Time.now)
      @next_timestamp_check = Time.at(@next_timestamp_check) if @next_timestamp_check.is_a? Numeric
      @next_timestamp_check = Time.parse(@next_timestamp_check) unless @next_timestamp_check.is_a? Time
    end

    def check_connection
      return status if Time.now < next_check
      return :no_http unless http_servers&.any?

      @last_check = Time.now
      available = []

      # TODO: Test if https is also available

      attempts = 0
      available = http_servers.map do |base_url|
        url = URI(File.join(base_url, 'entropy/TIMESTAMP'))
        ssl = url.scheme == 'https'

        begin
          attempts = attempts + 1
          resp = Net::HTTP.start(url.host, url.port, use_ssl: ssl, open_timeout: 1, read_timeout: 1) do |http|
            http.request_get(url.path)
          end

          if resp.is_a? Net::HTTPRedirection
            target = URI(resp['location'])
            target.path.gsub!('/entropy/TIMESTAMP', '')

            base_url.replace target.to_s
            redo if attempts <= 3
          end

          resp.value
          resp.body.to_i
        rescue Net::HTTPRequestTimeOut, Net::HTTPServerException, Net::HTTPError, Net::OpenTimeout, Errno::ECONNREFUSED, SocketError
          nil
        ensure
          attempts = 0
        end
      end.compact

      curr_status = available.any?

      if curr_status
        @failed_checks = 0
        backoff = 0

        @timestamp = available.max
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

      @status = curr_status ? :online : :unreachable
      @next_check = Time.now + CONNECTION_CHECK_INTERVAL + backoff
    end

    def test_speed(size: :small)
      raise 'No HTTP servers listed' if http_servers.nil? || http_servers.empty?
      raise 'Only sizes :small, :medium, and :large available' unless %i[small medium large].include? size

      files = {
        small: 'entropy/MIRROR_TEST', # 1000KiB
        medium: 'entropy/standard/portage/database/amd64/5/packages.db.light', # ~36MiB
        large: 'iso/daily/Sabayon_Linux_DAILY_amd64_tarball.tar.gz', # ~1GiB
      }
      file = files[size] || files[:small]

      http_servers.map do |base_url|
        uri = URI(File.join(base_url, file))
        ssl = uri.scheme == 'https'

        begin
          # pre = Time.now
          start = nil
          data = Net::HTTP.start(uri.host, uri.port, use_ssl: ssl, open_timeout: 10, read_timeout: 120) do |http|
            start = Time.now
            resp = http.get(uri.path)
            resp.body
            resp
          end
          # conn_diff = start - pre
          diff = Time.now - start

          data.value

          # TODO: Assert retrieved size
          # TODO: Track data rate and connection delay per server

          data.body.size / diff
        rescue Net::HTTPRequestTimeOut, Net::HTTPError
          nil
        end
      end.compact.max / 1000 / 1000 * 8
    end

    def timestamp
      return Time.at(@timestamp) if @timestamp && (@next_timestamp_check || Time.at(0)) < Time.now

      timestamp!
    end

    def timestamp!
      raise 'No HTTP servers listed' if http_servers.nil? || http_servers.empty?

      @timestamp = http_servers.map do |base_url|
        url = URI(File.join(base_url, 'entropy/TIMESTAMP'))
        ssl = url.scheme == 'https'

        begin
          resp = Net::HTTP.start(url.host, url.port, use_ssl: ssl, open_timeout: 2, read_timeout: 5) do |http|
            http.request_get(url.path)
          end

          resp.value
          resp.body.to_i
        rescue StandardError
          nil
        end
      end.compact.max

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
        last_check: last_check.to_i,
        next_check: next_check.to_i,
        next_timestamp_check: @next_timestamp_check.to_i
      }.compact.to_json(*params)
    end
  end
end
