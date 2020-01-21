# frozen_string_literal: false

require 'bundler/setup'
require 'google/apis/youtube_v3'
require 'json'
require 'optparse'

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

if $PROGRAM_NAME == __FILE__
  # パラメータの解析
  params = {}
  OptionParser.new do |opts|
    opts.on('-i', '--input VIDEO_ID', String, 'Youtube video id')
    opts.on('-o', '--output-dir [DIR]', String, 'Output directory')
  end.parse!(into: params)

  # デフォルトフォルダ comment
  video_id = params[:input]
  output_dir = params[:"output-dir"] || 'comment'

  # youtube api
  service = Google::Apis::YoutubeV3::YouTubeService.new
  service.key = File.read('youtube_api.key')

  # 結果を取得する
  comment_threads = service.fetch_all do |token, s|
    s.list_comment_threads('snippet, replies', max_results: 100, video_id: video_id, page_token: token)
  end

  items = { items: [] }
  raw_items = { raw_items: [] }
  comment_threads.each do |comment_thread|
    item = get_comment_properties(comment_thread.snippet.top_level_comment)

    # リプライを処理する
    # commentThread.list 取得できるリプライは五つまで
    # 残りのは comment.list で取得する
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

  # 処理したは #{output_dir}/#{video_id}_comments.json に書き込む
  # 未処理は  #{output_dir}/#{video_id}_raw_comments.json に書き込む
  FileUtils.mkpath(output_dir)
  output_path = File.join(output_dir, "#{video_id}_comments.json")
  raw_output_path = File.join(output_dir, "#{video_id}_raw_comments.json")

  File.open(output_path, 'w:UTF-8') do |file|
    file.write(JSON.pretty_generate(items))
  end

  File.open(raw_output_path, 'w:UTF-8') do |file|
    file.write(JSON.pretty_generate(raw_items))
  end
end
