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

def write_json_file(file_path, json)
  FileUtils.mkpath(File.dirname(file_path))

  File.open(file_path, 'w:UTF-8') do |output_file|
    output_file.write(JSON.pretty_generate(json))
  end
end

def process_and_write_file(processed_file, json)
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
    when 'liveChatPlaceholderItemRenderer'
      # 消されたのコメント？
    else
      LOGGER.info { "unknown chat_type: #{chat_type}" }
    end

    # 処理したチャットは #{output_dir}/#{video_id}.txt に書き込む
    processed_file.puts(chat_data.values.join(' ')) unless chat_data.empty?
  end
rescue StandardError => e
  LOGGER.error { "#{e.class}: #{e.message}\n#{e.backtrace.join("\n")}" }
end

def get_live_chat_replay(video_id, output_dir)
  uri = URI("https://www.youtube.com/watch?v=#{video_id}")

  LOGGER.info { "start get live chat replay, video url: #{uri}" }

  # パフォーマンス
  html_parse_time = 0.0
  request_time = 0.0
  write_json_file_time = 0.0
  process_and_write_file_time = 0.0

  # 未処理のチャットの.jsonファイル計数
  json_file_counter = 0
  # 処理したチャットの.txtファイル
  FileUtils.mkpath(output_dir)
  processed_file_path = File.join(output_dir, "#{video_id}.txt")

  File.open(processed_file_path, 'w:UTF-8') do |processed_file|
    Net::HTTP.start(uri.host, uri.port, use_ssl: (uri.scheme == 'https')) do |http|
      loop do
        # user-agentヘッダーは必要、でなければチャットリプレイは取得できない
        request = Net::HTTP::Get.new(uri)
        request['user-agent'] = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) '\
                                'Chrome/78.0.3904.108 Safari/537.36'
        request['accept-language'] = 'ja'

        # httpレスポンスのステータスコードは2xxでなければ例外を投げる
        response = nil
        request_time += Benchmark.realtime do
          response = http.request(request)
          response.value
        end

        LOGGER.debug('get_chat_replay') { "request_url = #{request.uri}" }

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

          html_parse_time += Benchmark.realtime do
            doc = Nokogiri::HTML(response.body)
            json_element = doc.xpath('//script').each do |script_node|
              if script_node.content.include?('window["ytInitialData"]')
                break script_node.content.scan(/"subMenuItems":\[.*?\]/).first
              end
            end
            json = JSON.parse("{#{json_element}}")
            continuation = json['subMenuItems'][1]['continuation']['reloadContinuationData']['continuation']
            uri = URI("https://www.youtube.com/live_chat_replay/get_live_chat_replay?continuation=#{continuation}&pbj=1")
          end
        else
          LOGGER.debug('get_chat_replay') { 'get live chat replay json' }

          json = JSON.parse(response.body)

          # 未処理のチャットを保存
          # 未処理のチャットのjsonファイル #{output_dir}/#{video_id}/#{video_id}_raw_live_chat_#.json
          json_file_dir = File.join(output_dir, video_id)
          json_file_name = "#{video_id}_raw_live_chat_#{format('%<counter>03d', counter: json_file_counter)}.json"
          json_file_path = File.join(json_file_dir, json_file_name)
          write_json_file_time += Benchmark.realtime { write_json_file(json_file_path, json) }
          json_file_counter += 1
          # チャットを処理して書き込む
          process_and_write_file_time += Benchmark.realtime { process_and_write_file(processed_file, json) }

          continuation = json.dig('response', 'continuationContents', 'liveChatContinuation', 'continuations', 0,
                                  'liveChatReplayContinuationData', 'continuation')
          if continuation
            uri = URI("https://www.youtube.com/live_chat_replay/get_live_chat_replay?continuation=#{continuation}&pbj=1")
          else
            LOGGER.debug('get_chat_replay') { 'end of live chat replay' }
            break
          end
        end
      end
    end
  end

  LOGGER.debug { "request time: #{request_time} sec" }
  LOGGER.debug { "html parse time: #{html_parse_time} sec" }
  LOGGER.debug { "write_json_file(): #{write_json_file_time} sec" }
  LOGGER.debug { "process_and_write_file(): #{process_and_write_file_time} sec" }
rescue StandardError => e
  LOGGER.error { "#{e.class}: #{e.message}\n#{e.backtrace.join("\n")}" }
end

def zip_dir(source_dir)
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
  files_path.each do |file_path|
    File.delete(file_path)
  end
  Dir.delete(source_dir)

  zip_file_path
end

def get_live_chat_replay_process(video_id, output_dir)
  # アーカイブのチャットリプレイの取得を始める
  get_live_chat_replay(video_id, output_dir)
  zip_file_path = zip_dir(File.join(output_dir, video_id))

  # zipしたファイルを #{output_dir}/raw に移動
  move_path = FileUtils.mkpath(File.join(output_dir, 'raw')).first
  FileUtils.mv(zip_file_path, move_path)

  LOGGER.info { "get live chat replay succeed, video_id: #{video_id}" }
end

if $PROGRAM_NAME == __FILE__
  # パラメータの解析
  params = {}
  OptionParser.new do |opts|
    opts.on('-d', '--debug', 'Debug mode switch')
    opts.on('-i', '--input INPUT', String, 'Allow 3 types input', '1. youtube video url',
            '2. youtube video id', '3. output file of get_playlist_videos_info.rb')
    opts.on('-o', '--output-dir [DIR]', String, 'Output directory, default is live_chat_replay/')
  end.parse!(into: params)

  begin
    # ログファイルの設定
    # log/get_live_chat_replay.log
    # debug modeでなければこのスクリプト実行する度にログファイルは上書きされる
    log_file_path = File.join('log', "#{File.basename($PROGRAM_NAME, '.rb')}.log")
    FileUtils.mkpath(File.dirname(log_file_path))
    log_file = File.open(log_file_path, 'w:UTF-8')
    log_file.sync = true
    log_level = params[:debug] ? :debug : :info
    LOGGER = Logger.new(log_file, level: log_level)
    LOGGER.info { "params: #{params}, program start" }

    # 引数の設定
    # デフォルトoutput_dirは live_chat_replay/
    input = params[:input]
    output_dir = params[:"output-dir"] || 'live_chat_replay'

    # main process
    elapsed_time = Benchmark.realtime do
      # inputはファイル
      if File.exist?(input)
        playlist_videos_info = JSON.parse(File.read(input))
        playlist_videos_info['items'].each do |item|
          video_id = item['id']
          get_live_chat_replay_process(video_id, output_dir)
        end
        # inputはYoutube url, Youtube video id
      else
        video_id =
          if input =~ URI::DEFAULT_PARSER.make_regexp
            URI.decode_www_form(URI(input).query).to_h['v']
          else
            input
          end
        get_live_chat_replay_process(video_id, output_dir)
      end
    end

    LOGGER.info { "elapsed time: #{elapsed_time} sec" }

  rescue StandardError => e
    LOGGER.error { "#{e.class}: #{e.message}\n#{e.backtrace.join("\n")}" }
  end

  # テスト: https://www.youtube.com/watch?v=S7qRc7SmMds
end