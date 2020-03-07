# frozen_string_literal: false

require 'bundler/setup'
require 'google/apis/youtube_v3'
require 'json'
require 'optparse'
require 'date'
require 'uri'
require 'logger'
require 'benchmark'

def write_json_file(file_path, json)
  FileUtils.mkpath(File.dirname(file_path))

  File.open(file_path, 'w:UTF-8') do |file|
    file.write(JSON.pretty_generate(json))
  end
end

def get_comment_properties(comment)
  item = {}
  item[:comment_id] = comment.id
  item[:author_id] = comment.snippet.author_channel_id["value"]
  item[:author_name] = comment.snippet.author_display_name
  item[:text_display] = comment.snippet.text_display
  item[:published_at] = comment.snippet.published_at
  updated_at = comment.snippet.updated_at
  item[:updated_at] = updated_at if updated_at != item[:published_at]

  item
end

def get_comments(service, video_id)
  # Youtube Data api でコメント取得する
  comment_threads = service.fetch_all do |token, s|
    s.list_comment_threads('snippet, replies', max_results: 100, video_id: video_id, page_token: token)
  end

  items = { items: [] }
  raw_items = { raw_items: [] }
  comment_threads.each do |comment_thread|
    item = get_comment_properties(comment_thread.snippet.top_level_comment)

    # リプライを処理する
    # commentThread.list api で取得できるリプライは五つまで
    # 残りのは comment.list api で取得する
    if comment_thread.snippet.total_reply_count != 0
      item[:replies] = []

      if comment_thread.snippet.total_reply_count == comment_thread.replies.comments.count
        comment_thread.replies.comments.each do |comment_reply|
          item[:replies].push(get_comment_properties(comment_reply))
        end
      else
        comment_replies = service.fetch_all do |token, s|
          s.list_comments('snippet', max_results: 100, parent_id: comment_thread.id, page_token: token)
        end
        comment_replies.each do |comment_reply|
          item[:replies].push(get_comment_properties(comment_reply))
        end
      end
    end
    items[:items].push(item)

    raw_items[:raw_items].push(comment_thread.to_h)
  end

  { items: items, raw_items: raw_items }
end

def get_comments_process(service, video_id, output_dir)
  comments = get_comments(service, video_id)

  # 処理したは #{output_dir}/#{file_name_prefix}_comments.json に書き込む
  # 未処理は  #{output_dir}/raw/#{file_name_prefix}_raw_comments.json に書き込む
  output_path = File.join(output_dir, "#{video_id}_comments.json")
  raw_output_path = File.join(output_dir, 'raw', "#{video_id}_raw_comments.json")

  write_json_file(output_path, comments[:items])
  write_json_file(raw_output_path, comments[:raw_items])

  LOGGER.info { "get comment succeed, video_id: #{video_id}" }
rescue StandardError => e
  LOGGER.error { "#{e.class}: #{e.message}\n#{e.backtrace.join("\n")}" }
end

if $PROGRAM_NAME == __FILE__
  # パラメータの解析
  params = {}
  OptionParser.new do |opts|
    opts.on('-d', '--debug', 'Debug mode switch')
    opts.on('-i', '--input INPUT', String, 'Allow 3 types input', '1. youtube video url',
            '2. youtube video id', '3. output file of get_playlist_videos_info.rb')
    opts.on('-o', '--output-dir [DIR]', String, 'Output directory, default is comment/')
  end.parse!(into: params)

  begin
    # ログファイルの設定
    # log/get_video_comment.log
    log_file_path = File.join('log', "#{File.basename($PROGRAM_NAME, '.rb')}.log")
    FileUtils.mkpath(File.dirname(log_file_path))
    log_file = File.open(log_file_path, 'w:UTF-8')
    log_file.sync = true
    log_level = params[:debug] ? :debug : :info
    LOGGER = Logger.new(log_file, level: log_level)
    LOGGER.info { "params: #{params}, program start" }

    # youtube api
    service = Google::Apis::YoutubeV3::YouTubeService.new
    service.key = File.read('youtube_api.key')

    # デフォルトoutput_dirは comment/
    input = params[:input]
    output_dir = params[:"output-dir"] || 'comment'

    # main process
    elapsed_time = Benchmark.realtime do
      # inputはファイル
      if File.exist?(input)
        playlist_videos_info = JSON.parse(File.read(input))
        playlist_videos_info['items'].each do |item|
          video_id = item['id']
          get_comments_process(service, video_id, output_dir)
        end
      # inputはYoutube url, Youtube video id
      else
        video_id =
          if input =~ URI::DEFAULT_PARSER.make_regexp
            URI.decode_www_form(URI(input).query).to_h['v']
          else
            input
          end
        get_comments_process(service, video_id, output_dir)
      end
    end

    LOGGER.info { "elapsed time: #{elapsed_time} sec" }

  rescue StandardError => e
    LOGGER.error { "#{e.class}: #{e.message}\n#{e.backtrace.join("\n")}" }
  end
end
