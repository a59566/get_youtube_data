# frozen_string_literal: false

require 'bundler/setup'
require 'net/http'
require 'uri'
require 'nokogiri'
require 'json'
require 'zip'
require 'logger'
require 'fileutils'
require 'optparse'
require 'benchmark'

def save_json_file(target_dir, video_id, json, json_file_counter)
  # 未処理のチャットのjsonファイル #{target_dir}/#{video_id}/#{video_id}_raw_live_chat_#.json
  json_file_dir = FileUtils.mkpath("#{target_dir}/#{video_id}").first
  json_file_name = "#{video_id}_raw_live_chat_#{format('%<counter>03d', counter: json_file_counter)}.json"
  json_file_path = File.join(json_file_dir, json_file_name)
  File.open(json_file_path, 'w:UTF-8') do |output_file|
    output_file.write(JSON.pretty_generate(json))
  end

  LOGGER.debug('write_json_file') { "write #{json_file_path}" }
end

def write_processed_file(processed_file, json)
  # この部分はjson掘り下げてチャットを抽出する
  chat_records = json.dig('response', 'continuationContents', 'liveChatContinuation', 'actions')
  chat_records&.each do |chat_record|
    # スパチャはもう一つ addLiveChatTickerItemAction の部分がある(チャット欄の上に留まるのやつ)
    # チャットは重複しているのでスキップ
    item = chat_record.dig('replayChatItemAction', 'actions', 0, 'addChatItemAction', 'item')
    next unless item

    chat_type = item.keys.first
    # 処理したチャット {:timestamp(チャットの時間), :message(チャットの内容)}
    chat_data = {}

    # チャット抽出用lambdas
    combine_message = ->(message, message_piece) { message << message_piece['text'] }
    get_timestamp = -> { item[chat_type]['timestampText']['simpleText'] }
    get_message = -> { item.dig(chat_type, 'message', 'runs')&.inject('', &combine_message) }
    # get_author = -> { item[chat_type]['authorName']['simpleText'] }
    # get_super_chat_amount = -> { item[chat_type]['purchaseAmountText']['simpleText'] }

    case chat_type
    when 'liveChatTextMessageRenderer'
      # 通常チャット
      chat_data[:timestamp] = get_timestamp.call
      chat_data[:message] = get_message.call
      # chat_data[:author] = get_author.call
    when 'liveChatPaidMessageRenderer'
      # スパチャ
      chat_data[:timestamp] = get_timestamp.call
      chat_data[:message] = get_message.call
      # コメントなしのスパチャはスキップ
      next if chat_data[:message].nil?
      # chat_data[:author] = get_author.call
      # chat_data[:super_chat_amount] = get_super_chat_amount.call
    when 'liveChatPaidStickerRenderer'
      # スーパーステッカー
      # chat_data[:timestamp] = get_timestamp.call
      # chat_data[:author] = get_author.call
      # chat_data[:super_chat_amount] = get_super_chat_amount.call
    when 'liveChatLegacyPaidMessageRenderer'
      # 新規メンバー
    when 'liveChatViewerEngagementMessageRenderer'
      # Youtubeのシステムメッセージ：
      # "チャットのリプレイがオンになっています。プレミア公開時に表示されたメッセージは、ここに表示されます。"
    else
      LOGGER.info { "unknown chat_type: #{chat_type}" }
    end

    # 処理したチャットは #{target_dir}/#{video_id}.txt に書き込む
    processed_file.puts(chat_data.values.join(' ')) unless chat_data.empty?
  end
rescue StandardError => e
  LOGGER.error { "#{e.class}: #{e.message}\n#{e.backtrace.join("\n")}" }
end

def get_live_chat_replay(url, target_dir)
  uri = URI(url)
  video_id = URI.decode_www_form(uri.query).to_h['v']

  LOGGER.info { "start get live chat replay, video url: #{url}" }

  # 未処理のチャットの.jsonファイル計数
  json_file_counter = 0
  # 処理したチャットの.txtファイル
  FileUtils.mkpath(target_dir)
  processed_file_path = File.join(target_dir, "#{video_id}.txt")

  File.open(processed_file_path, 'w:UTF-8') do |processed_file|
    Net::HTTP.start(uri.host, uri.port, use_ssl: (uri.scheme == 'https')) do |http|
      loop do
        # user-agentヘッダーは必要、でなければチャットリプレイは取得できない
        request = Net::HTTP::Get.new(uri)
        request['user-agent'] = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) '\
                                'Chrome/78.0.3904.108 Safari/537.36'
        request['accept-language'] = 'ja'

        # httpレスポンスのステータスコードは2xxでなければ例外を投げる
        response = http.request(request)
        response.value

        LOGGER.debug('get_chat_replay') { "request_url: #{request.uri}" }

        # チャットリプレイの取得は連続で以下のurlをGETでrequest
        # https://www.youtube.com/live_chat_replay/get_live_chat_replay?continuation=#{continuation}&pbj=1
        # 毎回取得できるのチャットリプレイは数十件だけ、続いては#{continuation}の部分を換えてrequest
        # #{continuation}を取得するには2パターンがある
        # 1. uriは https://www.youtube.com/watch?v=#{video_id}
        #    このパターンはループの初回だけ、レスポンスは普通のhtml
        #    continuationの値は "<script>window["ytInitialData"] = {json形式のデータ} ...</script>" json部分の中にいます
        # 2. uriは https://www.youtube.com/live_chat_replay/get_live_chat_replay?continuation=#{continuation}&pbj=1
        #    ループの初回以外はこのパターン、レスポンスはjson形式のデータ
        #    continuationの値はjsonの中にいます
        # pbj=1を付けばjson形式のレスポンス取得できる
        if response.body.start_with?('<!doctype html>')
          LOGGER.debug('get_chat_replay') { 'get html page' }

          doc = Nokogiri::HTML(response.body)
          json_element = doc.xpath('//script').each do |script_node|
            if script_node.content.include?('window["ytInitialData"]')
              break script_node.content.scan(/"subMenuItems":\[.*?\]/).first
            end
          end
          json = JSON.parse("{#{json_element}}")
          continuation = json['subMenuItems'][1]['continuation']['reloadContinuationData']['continuation']
          uri = URI("https://www.youtube.com/live_chat_replay/get_live_chat_replay?continuation=#{continuation}&pbj=1")

          LOGGER.debug('get_chat_replay') { "first continuation: '#{continuation}'" }
        else
          LOGGER.debug('get_chat_replay') { 'get live chat replay json' }

          json = JSON.parse(response.body)

          # 未処理のチャットを保存
          save_json_file(target_dir, video_id, json, json_file_counter)
          json_file_counter += 1
          # チャットを処理して書き込む
          write_processed_file(processed_file, json)

          continuation = json.dig('response', 'continuationContents', 'liveChatContinuation', 'continuations', 0,
                                  'liveChatReplayContinuationData', 'continuation')
          if continuation
            uri = URI("https://www.youtube.com/live_chat_replay/get_live_chat_replay?continuation=#{continuation}&pbj=1")

            LOGGER.debug('get_chat_replay') { "next continuation: '#{continuation}'" }
          else
            LOGGER.debug('get_chat_replay') { 'end of live chat replay' }
            break
          end
        end
      end
    end
  end

  LOGGER.info { 'get live chat replay succeed' }
rescue StandardError => e
  LOGGER.error { "#{e.class}: #{e.message}\n#{e.backtrace.join("\n")}" }
end

def zip_dir(source_dir, delete_source_dir = true)
  files_path = Dir.glob("#{source_dir}/*")
  zip_file_path = "#{source_dir}.zip"

  # 既存のzipファイルを削除する
  File.delete(zip_file_path) if File.exist?(zip_file_path)

  # 圧縮する
  Zip.unicode_names = true
  Zip::File.open(zip_file_path, Zip::File::CREATE) do |zip_file|
    files_path.each do |file_path|
      in_zip_path = File.join(File.basename(source_dir), File.basename(file_path))
      zip_file.add(in_zip_path, file_path)
    end
  end

  # source dirを削除する
  return unless delete_source_dir

  files_path.each do |file_path|
    File.delete(file_path)
  end
  Dir.delete(source_dir)
end

if $PROGRAM_NAME == __FILE__
  # パラメータの解析
  params = {}
  OptionParser.new do |opts|
    opts.on('-d', '--debug', 'Debug mode switch')
    opts.on('-o', '--output-dir [OUTPUT_DIR]', String, 'Output directory')
    opts.on('-u', '--url URL', String, 'Youtube video url')
  end.parse!(into: params)

  # ログファイルの設定
  log_file = File.open("#{File.basename($PROGRAM_NAME, '.rb')}.log", 'w:UTF-8')
  log_file.sync = true
  log_level = params[:debug] ? :debug : :info
  LOGGER = Logger.new(log_file, level: log_level)
  LOGGER.info { "params: #{params}, program start" }

  # 引数の設定
  target_dir = params[:"output-dir"] || 'live_chat_replay'
  url = params[:url]
  video_id = URI.decode_www_form(URI(url).query).to_h['v']

  # アーカイブのチャットリプレイの取得を始める
  elapsed_time = Benchmark.realtime do
    get_live_chat_replay(url, target_dir)
    zip_dir(File.join(target_dir, video_id))
  end

  LOGGER.info { "elapsed time: #{elapsed_time} sec" }

  # テスト: 'https://www.youtube.com/watch?v=S7qRc7SmMds'
end