require 'sinatra/base'
require 'pathname'
require 'digest/sha2'
require 'redis'
require 'json'
require 'rack/request'
require 'mysql2-cs-bind'

def development?
  ENV['RACK_ENV'] != 'production'
end

if development?
  require 'rack-lineprof'
end

module Isucon4
  class App < Sinatra::Base
    set :public_folder, "#{__dir__}/../public"
    ADS_DIR = Pathname.new(__dir__).join('ads')
    LOG_DIR = Pathname.new(__dir__).join('logs')
    ADS_DIR.mkpath unless ADS_DIR.exist?
    LOG_DIR.mkpath unless LOG_DIR.exist?

    if development?
      use Rack::Lineprof, profile: 'app.rb'
    end

    helpers do
      def advertiser_id
        request.env['HTTP_X_ADVERTISER_ID']
      end

      def redis
        @redis ||=
          if ENV['RACK_ENV'] == 'production'
            # isucon2 private ip
            Redis.new(host: '10.11.54.171', port: 6379)
          else
            Redis.current
          end
      end

      def local_redis
        @local_redis ||= Redis.current
      end

      def mysql
        return @mysql if defined?(@mysql)

        @mysql = Mysql2::Client.new(
          host: '10.11.54.172',
          port: 3306,
          username: 'isucon',
          password: 'bonnou2014',
          database: 'isucon',
          reconnect: true,
        )
      end

      def init_mysql
        mysql.query(<<-EOS)
          DROP TABLE IF EXISTS logs;
        EOS

        mysql.query(<<-EOS)
          CREATE TABLE isucon.logs (
            `id` INT UNSIGNED NOT NULL AUTO_INCREMENT,
            `advertiser` VARCHAR(255) DEFAULT NULL,
            `advertiser_id` VARCHAR(255) DEFAULT NULL,
            `isuad` VARCHAR(255) DEFAULT NULL,
            `useragent` VARCHAR(255) DEFAULT NULL,
            PRIMARY KEY (`id`),
            KEY `index_advertiser` (`advertiser`)
          ) ENGINE=InnoDB;
        EOS
      end

      def ad_key(slot, id)
        "isu4:ad:#{slot}-#{id}"
      end

      def asset_key(slot, id)
        "isu4:asset:#{slot}-#{id}"
      end

      def advertiser_key(id)
        "isu4:advertiser:#{id}"
      end

      def slot_key(slot)
        "isu4:slot:#{slot}"
      end

      def next_ad_id
        redis.incr('isu4:ad-next').to_i
      end

      def next_ad(slot)
        key = slot_key(slot)

        id = redis.rpoplpush(key, key)
        unless id
          return nil
        end

        ad = get_ad(slot, id)
        if ad
          ad
        else
          redis.lrem(key, 0, id)
          next_ad(slot)
        end
      end

      def get_ad(slot, id)
        key = ad_key(slot, id)
        ad = redis.hgetall(key)

        return nil if !ad || ad.empty?
        ad['impressions'] = ad['impressions'].to_i
        ad['type'] = nil if ad['type'] == ""

        ad
      end

      def decode_user_key(id)
        return {gender: :unknown, age: nil} if !id || id.empty?
        gender, age = id.split('/', 2).map(&:to_i)
        {gender: gender == 0 ? :female : :male, age: age}
      end

      def get_log(id)
        advertiser = id.split('/').last
        rows = mysql.xquery("SELECT * FROM logs WHERE advertiser = ?", advertiser)
        return {} if rows.size == 0

        #path = LOG_DIR.join(id.split('/').last)
        #return {} unless path.exist?

        rows.map do |row|
          ad_id, user, agent = row['advertiser_id'], row['isuad'], row['useragent']
          {ad_id: ad_id, user: user, agent: agent && !agent.empty? ? agent : :unknown}.merge(decode_user_key(user))
        end.group_by { |click| click[:ad_id] }

        # open(path, 'r') do |io|
        #   io.flock File::LOCK_SH
        #   io.read.each_line.map do |line|
        #     ad_id, user, agent = line.chomp.split(?\t,3)
        #     {ad_id: ad_id, user: user, agent: agent && !agent.empty? ? agent : :unknown}.merge(decode_user_key(user))
        #   end.group_by { |click| click[:ad_id] }
        # end
      end
    end

    get '/' do
      Pathname.new(self.class.public_folder).join('index.html').read
    end

    post '/slots/:slot/ads' do
      unless advertiser_id
        halt 400
      end

      slot = params[:slot]
      asset = params[:asset][:tempfile]

      id = next_ad_id
      key = ad_key(slot, id)

      redis.hmset(
        key,
        'slot', slot,
        'id', id,
        'title', params[:title],
        'type', params[:type] || params[:asset][:type] || 'video/mp4',
        'advertiser', advertiser_id,
        'destination', params[:destination],
        'impressions', 0,
        'asset', url("/slots/#{slot}/ads/#{id}/asset"),
        'counter', url("/slots/#{slot}/ads/#{id}/count"),
        'redirect', url("/slots/#{slot}/ads/#{id}/redirect"),
      )
      File.write("/tmp/movie/#{asset_key(slot, id)}", asset.read)
      #local_redis.set(asset_key(slot, id), asset.read)
      redis.rpush(slot_key(slot), id)
      redis.sadd(advertiser_key(advertiser_id), key)

      content_type :json
      get_ad(slot, id).to_json
    end

    get '/slots/:slot/ad' do
      ad = next_ad(params[:slot])
      if ad
        redirect "/slots/#{params[:slot]}/ads/#{ad['id']}"
      else
        status 404
        content_type :json
        {error: :not_found}.to_json
      end
    end

    get '/slots/:slot/ads/:id' do
      content_type :json
      ad = get_ad(params[:slot], params[:id])
      if ad
        ad.to_json
      else
        status 404
        content_type :json
        {error: :not_found}.to_json
      end
    end

    get '/slots/:slot/ads/:id/asset' do
      ad = get_ad(params[:slot], params[:id])
      if ad
        content_type ad['type'] || 'application/octet-stream'
        data = File.read("/tmp/movie/#{asset_key(params[:slot],params[:id])}")
        #data = local_redis.get(asset_key(params[:slot],params[:id])).b

        # Chrome sends us Range request even we declines...
        range = request.env['HTTP_RANGE']
        case
        when !range || range.empty?
          data
        when /\Abytes=(\d+)?-(\d+)?\z/ === range
          head, tail = $1, $2
          halt 416 if !head && !tail
          head ||= 0
          tail ||= data.size-1

          head, tail = head.to_i, tail.to_i
          halt 416 if head < 0 || head >= data.size || tail < 0

          status 206
          headers 'Content-Range' => "bytes #{head}-#{tail}/#{data.size}"
          data[head.to_i..tail.to_i]
        else
          # We don't respond to multiple Range requests and non-`bytes` Range request
          halt 416
        end
      else
        status 404
        content_type :json
        {error: :not_found}.to_json
      end
    end

    post '/slots/:slot/ads/:id/count' do
      key = ad_key(params[:slot], params[:id])

      unless redis.exists(key)
        status 404
        content_type :json
        next {error: :not_found}.to_json
      end

      redis.hincrby(key, 'impressions', 1)

      status 204
    end

    get '/slots/:slot/ads/:id/redirect' do
      ad = get_ad(params[:slot], params[:id])
      unless ad
        status 404
        content_type :json
        next {error: :not_found}.to_json
      end


      advertiser_id = ad['advertiser'].split('/').last
      ad_id = ad['id']
      isuad = request.cookies['isuad']
      user_agent = request.user_agent

      mysql.xquery("INSERT INTO logs (advertiser, advertiser_id, isuad, useragent) VALUES (?,?,?,?)",
        advertiser_id, ad_id, isuad, user_agent)

      # open(LOG_DIR.join(ad['advertiser'].split('/').last), 'a') do |io|
      #  io.flock File::LOCK_EX
      #  io.puts([ad['id'], request.cookies['iscduad'], request.user_agent].join(?\t))
      # end

      redirect ad['destination']
    end

    get '/me/report' do
      if !advertiser_id || advertiser_id == ""
        halt 401
      end

      content_type :json

      {}.tap do |report|
        redis.smembers(advertiser_key(advertiser_id)).each do |ad_key|
          ad = redis.hgetall(ad_key)
          next unless ad
          ad['impressions'] = ad['impressions'].to_i

          report[ad['id']] = {ad: ad, clicks: 0, impressions: ad['impressions']}
        end

        get_log(advertiser_id).each do |ad_id, clicks|
          report[ad_id][:clicks] = clicks.size
        end
      end.to_json
    end

    get '/me/final_report' do
      if !advertiser_id || advertiser_id == ""
        halt 401
      end

      content_type :json

      {}.tap do |reports|
        redis.smembers(advertiser_key(advertiser_id)).each do |ad_key|
          ad = redis.hgetall(ad_key)
          next unless ad
          ad['impressions'] = ad['impressions'].to_i

          reports[ad['id']] = {ad: ad, clicks: 0, impressions: ad['impressions']}
        end

        logs = get_log(advertiser_id)

        reports.each do |ad_id, report|
          log = logs[ad_id] || []
          report[:clicks] = log.size

          breakdown = report[:breakdown] = {}

          breakdown[:gender] = log.group_by{ |_| _[:gender] }.map{ |k,v| [k,v.size] }.to_h
          breakdown[:agents] = log.group_by{ |_| _[:agent] }.map{ |k,v| [k,v.size] }.to_h
          breakdown[:generations] = log.group_by{ |_| _[:age] ? _[:age].to_i / 10 : :unknown }.map{ |k,v| [k,v.size] }.to_h
        end
      end.to_json
    end

    post '/initialize' do
      redis.keys('isu4:*').each_slice(1000).map do |keys|
        redis.del(*keys)
      end

      init_mysql

      #LOG_DIR.children.each(&:delete)
      system('rm -rf /tmp/movie')
      system('mkdir /tmp/movie')

      content_type 'text/plain'
      "OK"
    end
  end
end
