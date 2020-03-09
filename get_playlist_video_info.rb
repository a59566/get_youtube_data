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
    opts.on('-i', '--input INPUT', String, 'Allow 2 types input', '1. youtube playlist url',
            '2. youtube playlist id')
    opts.on('-o', '--output-dir [DIR]', String, 'Output directory, default is playlist/')
  end.parse!(into: params)
  input = params[:input]
  output_dir = params[:"output-dir"] || 'playlist'

  # google api
  service = Google::Apis::YoutubeV3::YouTubeService.new
  service.key = File.read('youtube_api.key')

  playlist_id =
    if input =~ URI::DEFAULT_PARSER.make_regexp
      URI.decode_www_form(URI(input).query).to_h['list']
    else
      input
    end

  # 結果を取得して #{output_dir}/#{play_list_id}.json に書き込む
  playlist_items = service.fetch_all do |token, s|
    s.list_playlist_items('contentDetails, snippet', max_results: 50, playlist_id: playlist_id, page_token: token)
  end

  video_infos = []

  playlist_items.each do |item|
    video_info = {}
    video_info[:id] = item.content_details.video_id
    video_info[:title] = item.snippet.title
    video_info[:description] = item.snippet.description
    video_info[:published_at] = item.content_details.video_published_at

    video_infos.push(video_info)
  end

  FileUtils.mkpath(output_dir)
  output_file = "#{playlist_id}.json"
  output_path = File.join(output_dir, output_file)

  File.open(output_path, 'w:UTF-8') do |file|
    file.puts(JSON.pretty_generate(video_infos))
  end
end
