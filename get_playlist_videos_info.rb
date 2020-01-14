# frozen_string_literal: false

require 'bundler/setup'
require 'net/http'
require 'uri'
require 'optparse'
require 'benchmark'
require 'google/apis/youtube_v3'
require 'json'

if $PROGRAM_NAME == __FILE__
  # パラメータの解析
  params = {}
  OptionParser.new do |opts|
    opts.on('-i', '--input PLAYLIST_ID', String, 'Youtube playlist id')
    opts.on('-o', '--output-dir [DIR]', String, 'Output directory')
  end.parse!(into: params)
  play_list_id = params[:input]
  output_dir = params[:"output-dir"]

  # google api
  service = Google::Apis::YoutubeV3::YouTubeService.new
  service.key = File.read('youtube_api.key')

  # 結果を取得して #{play_list_id}.json に書き込む
  playlist_items = service.fetch_all do |token, s|
    s.list_playlist_items('contentDetails, snippet', max_results: 50, playlist_id: play_list_id, page_token: token)
  end

  video_properties = { items: [] }

  playlist_items.each do |item|
    video_property = {}
    video_property[:id] = item.content_details.video_id
    video_property[:title] = item.snippet.title
    video_property[:description] = item.snippet.description
    video_property[:published_at] = item.content_details.video_published_at

    video_properties[:items].push(video_property)
  end

  FileUtils.mkpath(output_dir) if output_dir
  output_file = "#{play_list_id}.json"
  output_path = output_dir ? File.join(output_dir, output_file) : output_file

  File.open(output_path, 'w:UTF-8') do |file|
    file.puts(JSON.pretty_generate(video_properties))
  end
end
