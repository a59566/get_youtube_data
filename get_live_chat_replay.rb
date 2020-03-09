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

def get_chat_replay_items(json)
  # チャット抽出用lambda
  get_common_data = lambda do |chat_data|
    common_data = {}
    common_data[:timestamp] = chat_data['timestampText']['simpleText']
    common_data[:author_id] = chat_data['authorExternalChannelId']
    common_data[:author_name] = chat_data['authorName']['simpleText']
    common_data
  end
  get_message_data = lambda do |chat_data|
    chat_data.dig('message', 'runs')&.inject('') do |message, message_piece|
      message << message_piece['text']
    end
  end

  # 処理したチャット
  chat_replay_items = []

  actions = json.dig('response', 'continuationContents', 'liveChatContinuation', 'actions')
  actions&.each do |action|
    # スパチャはもう一つ addLiveChatTickerItemAction の部分がある(チャット欄の上に留まるのやつ)
    # チャットは重複しているのでスキップ
    item = action.dig('replayChatItemAction', 'actions', 0, 'addChatItemAction', 'item')
    next unless item

    chat_type = item.keys.first
    chat_data = item[chat_type]
    # 処理したチャット {:timestamp(チャットの時間), :author_id(チャットの作者ID),
    # :author_name(チャットの作者), :message(チャットの内容)}
    case chat_type
    when 'liveChatTextMessageRenderer'
      # 通常チャット
      chat_replay_item = get_common_data.call(chat_data)
      chat_replay_item[:message] = get_message_data.call(chat_data)

      chat_replay_items.push(chat_replay_item)
    when 'liveChatPaidMessageRenderer'
      # スパチャ
      chat_replay_item = get_common_data.call(chat_data)
      chat_replay_item[:message] = get_message_data.call(chat_data)
      chat_replay_item[:super_chat_amount] = chat_data['purchaseAmountText']['simpleText']

      chat_replay_items.push(chat_replay_item)
    when 'liveChatPaidStickerRenderer'
      # スーパーステッカー
    when 'liveChatLegacyPaidMessageRenderer'
      # 新規メンバー
    when 'liveChatViewerEngagementMessageRenderer'
      # Youtubeのシステムメッセージ：
      # "チャットのリプレイがオンになっています。プレミア公開時に表示されたメッセージは、ここに表示されます。"
    when 'liveChatPlaceholderItemRenderer'
      # 消されたのコメント(未確認)
    else
      LOGGER.debug { "unknown chat_type: #{chat_type}" }
    end
  end

  chat_replay_items
end

def get_chat_replay(video_id)
  uri = URI("https://www.youtube.com/watch?v=#{video_id}")

  # パフォーマンス計測
  html_parse_time = 0.0
  request_time = 0.0
  chat_replay_process_time = 0.0
  raw_chat_replay_process_time = 0.0

  # 処理したチャットと未処理のチャット
  chat_replay = []
  raw_chat_replay = []

  Net::HTTP.start(uri.host, uri.port, use_ssl: (uri.scheme == 'https')) do |http|
    loop do
      # user-agentヘッダーは必要、でなければチャットリプレイは取得できない
      request = Net::HTTP::Get.new(uri)
      request['user-agent'] = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '\
                              'AppleWebKit/537.36 (KHTML, like Gecko) '\
                              'Chrome/78.0.3904.108 Safari/537.36'
      request['accept-language'] = 'ja'

      # httpレスポンスのステータスコードは2xxでなければ例外を投げる
      response = nil
      request_time += Benchmark.realtime do
        response = http.request(request)
        response.value
      end

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
        html_parse_time += Benchmark.realtime do
          doc = Nokogiri::HTML(response.body)
          sub_menu_items = doc.xpath('//script').each do |script_node|
            if script_node.content.include?('window["ytInitialData"]')
              break script_node.content.scan(/"subMenuItems":\[.*?\]/).first
            end
          end
          json = JSON.parse("{#{sub_menu_items}}")
          continuation = json['subMenuItems'][1]['continuation']['reloadContinuationData']['continuation']
          uri = URI("https://www.youtube.com/live_chat_replay/get_live_chat_replay?continuation=#{continuation}&pbj=1")
        end
      else
        json = JSON.parse(response.body)
        continuation = json.dig('response', 'continuationContents', 'liveChatContinuation', 'continuations', 0,
                                'liveChatReplayContinuationData', 'continuation')
        uri = URI("https://www.youtube.com/live_chat_replay/get_live_chat_replay?continuation=#{continuation}&pbj=1")

        break unless continuation

        chat_replay_process_time += Benchmark.realtime do
          chat_replay.concat(get_chat_replay_items(json))
        end

        # 未処理の書き込みはdebugモードだけ
        raw_chat_replay_process_time +=
          if DEBUG_MODE
            Benchmark.realtime do
              raw_chat_replay.push(json)
            end
          else
            0
          end
      end
    end
  end

  LOGGER.debug { "request time: #{request_time} sec" }
  LOGGER.debug { "html parse time: #{html_parse_time} sec" }
  LOGGER.debug { "chat replay process time: #{chat_replay_process_time} sec" }
  LOGGER.debug { "raw chat replay process time: #{raw_chat_replay_process_time} sec" }

  { chat_replay: chat_replay, raw_chat_replay: raw_chat_replay }
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

def get_chat_replay_process(video_id, output_dir)
  # アーカイブのチャットリプレイの取得を始める
  LOGGER.info { "start to get live chat replay, video id: #{video_id}" }
  chat_replay = get_chat_replay(video_id)

  write_file_time = Benchmark.realtime do
    output_path = File.join(output_dir, "#{video_id}_live_chat_replay.json")
    write_json_file(output_path, chat_replay[:chat_replay])
  end

  # 未処理の書き込みはdebugモードだけ
  write_raw_file_time =
    if DEBUG_MODE
      Benchmark.realtime do
        raw_output_dir = File.join(output_dir, 'raw', video_id)
        chat_replay[:raw_chat_replay].each_with_index do |raw, index|
          raw_output_path = File.join(raw_output_dir, "raw_#{video_id}_live_chat_replay_#{index}.json")
          write_json_file(raw_output_path, raw)
        end
        zip_dir(raw_output_dir)
      end
    else
      0
    end

  LOGGER.debug { "write file time: #{write_file_time} sec" }
  LOGGER.debug { "write raw file time: #{write_raw_file_time} sec" }
  LOGGER.info { 'get live chat replay succeed' }
rescue StandardError => e
  LOGGER.error { "#{e.class}: #{e.message}\n#{e.backtrace.join("\n")}" }
end

if $PROGRAM_NAME == __FILE__
  # パラメータの解析
  params = {}
  OptionParser.new do |opts|
    opts.on('-d', '--debug', 'Debug mode switch')
    opts.on('-i', '--input INPUT', String, 'Allow 3 types input', '1. youtube video url',
            '2. youtube video id', '3. output file of get_playlist_video_info.rb')
    opts.on('-o', '--output-dir [DIR]', String, 'Output directory, default is live_chat_replay/')
  end.parse!(into: params)

  begin
    DEBUG_MODE = params[:debug]

    # ログファイルの設定
    # log/get_live_chat_replay.log
    log_file_path = File.join('log', "#{File.basename($PROGRAM_NAME, '.rb')}.log")
    FileUtils.mkpath(File.dirname(log_file_path))
    log_file = File.open(log_file_path, 'w:UTF-8')
    log_file.sync = true
    log_level = DEBUG_MODE ? :debug : :info
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
        # output_dir は #{output_dir}/#{playlist_id}
        playlist_id = File.basename(input, '.json')
        output_dir = File.join(output_dir, playlist_id)

        playlist_video_infos = JSON.parse(File.read(input))
        playlist_video_infos.each do |video_info|
          video_id = video_info['id']
          get_chat_replay_process(video_id, output_dir)
        end
        # inputはYoutube url, Youtube video id
      else
        video_id =
          if input =~ URI::DEFAULT_PARSER.make_regexp
            URI.decode_www_form(URI(input).query).to_h['v']
          else
            input
          end
        get_chat_replay_process(video_id, output_dir)
      end
    end

    LOGGER.info { "elapsed time: #{elapsed_time} sec" }
  rescue StandardError => e
    LOGGER.error { "#{e.class}: #{e.message}\n#{e.backtrace.join("\n")}" }
  end
end