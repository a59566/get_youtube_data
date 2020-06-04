# Youtube資訊取得script
`get_playlist_video_info.rb` : 取得播放清單資訊、輸出可以給以下兩個script使用  
`get_comment.rb` : 取得影片留言  
`get_live_chat_replay.rb` : 取得重播的聊天室留言  

# 事前準備
`get_playlist_video_info.rb`と`get_comment.rb`需要用到**Google API Key**    
請自行向Google申請  
```
$ git clone https://github.com/a59566/get_youtube_data.git
$ cd get_youtube_data/
$ bundle

# Google API Key はスクリプトと同じディレクトリに youtube_api.key 書き込んでおく
$ printf "Your Google API Key" > youtube_api.key
```

# 使用方法
### get_playlist_video_info.rb
```
$ ruby get_playlist_video_info.rb -h
  Usage: get_playlist_video_info [options]
      -i, --input INPUT                Allow 2 types input
                                       1. youtube playlist url
                                       2. youtube playlist id
      -o, --output-dir [DIR]           Output directory, default is playlist/
```
例:  
`$ ruby get_playlist_video_info.rb -i 'https://www.youtube.com/playlist?list=PLK_65KbO9TBtkDTedvAA_Znt2Mu6ha73L'`  
或者  
`$ ruby get_playlist_video_info.rb -i PLK_65KbO9TBtkDTedvAA_Znt2Mu6ha73L`    
  
輸出:  
`playlist/PLK_65KbO9TBtkDTedvAA_Znt2Mu6ha73L.json`  
```
{
  "playlist_info": {
    "id": "PLK_65KbO9TBtkDTedvAA_Znt2Mu6ha73L",
    "title": "メタルウルフカオス",
    "description": "",
    "published_at": "2020-02-26T12:51:01+00:00"
  },
  "video_infos": [
    {
      "id": "YtU7yYS4JEI",
      "title": "【メタルウルフカオスXD】結局何ゲーなのかよくわからないゲーム01",
      "description": "ロボットと大統領が出てくることは把握しました。\n本日も....
      "published_at": "2020-02-26T14:38:33+00:00"
    },
    ...
```
---
  
### get_comment.rb
```
$ ruby get_comment.rb -h
  Usage: get_comment [options]
      -d, --debug                      Debug mode switch, will save raw data
      -i, --input INPUT                Allow 3 types input
                                       1. youtube video url
                                       2. youtube video id
                                       3. output file of get_playlist_video_info.rb
      -o, --output-dir [DIR]           Output directory, default is comment/
```
例:  
`$ ruby get_comment.rb -i 'https://www.youtube.com/watch?v=Jby8IBtSJpc'`  
`$ ruby get_comment.rb -i nBhBVB70Imk`  
`$ ruby get_comment.rb -i playlist/PLK_65KbO9TBtkDTedvAA_Znt2Mu6ha73L.json`  
任選一種  
  
輸出:  
`comment/PLK_65KbO9TBtkDTedvAA_Znt2Mu6ha73L/YtU7yYS4JEI_comment.json`  
```
[
  {
    "comment_id": "UgwdpuChd8-Vqtdq9pd4AaABAg",
    "author_id": "UCTQeS3yaE-LrJ_UoypkMHqw",
    "author_name": ...
    "text_display": "どのゲームでも安心して楽しみにして視聴できる。そう、...
    "published_at": "2020-03-04T08:32:08+00:00"
  },
  {
    "comment_id": "UgyoxaKKkqaqGvLpMCx4AaABAg",
    "author_id": "UCtJlPjSPp-vUdrrmZFR1cSw",
    "author_name": ...
    "text_display": "大統領シャウト！について<br />『大統領...
    "published_at": "2020-03-03T22:19:16+00:00"
  },
  ...
```
---
  
### get_live_chat_replay.rb
```
$ ruby get_live_chat_replay.rb -h
  Usage: get_live_chat_replay [options]
      -d, --debug                      Debug mode switch, will save raw data and log performance info
      -i, --input INPUT                Allow 3 types input
                                       1. youtube video url
                                       2. youtube video id
                                       3. output file of get_playlist_video_info.rb
      -o, --output-dir [DIR]           Output directory, default is live_chat_replay/
```
例:  
`$ ruby get_live_chat_replay.rb -i S7qRc7SmMds`  
  
輸出:  
`live_chat_replay/S7qRc7SmMds_live_chat_replay.json`  
```
[
  {
    "timestamp": "-0:20",
    "author_id": "UC0ZbGCfR09J__CXXcwjbu-g",
    "author_name": ...
    "message": "俺のアイドル部はふーさんから始まった、ふーさんが原点、10万人は本当に嬉しい…"
  },
  {
    "timestamp": "-0:20",
    "author_id": "UCuLUAW9MLTKHMe4FOaATrOw",
    "author_name": ...
    "message": "一体何が始まるんです？"
  },
  ...
```
  
# 參考資料
[PythonでYouTube Liveのアーカイブからチャット（コメント）を取得する](http://watagassy.hatenablog.com/entry/2018/10/06/002628)  
[\[Python\] youtubeliveのアーカイブの見どころを特定する](https://qiita.com/okamoto950712/items/0d4736c7be251532a03f)
  
# License
Code released under MIT License