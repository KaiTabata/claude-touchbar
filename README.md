# claude-touchbar

Touch Bar 付き MacBook で、[Claude Code](https://claude.com/claude-code) のセッション状況を Touch Bar に表示する小さなアプリです。

> **これは自分用に作ったものです。** 自分の環境（M2 MacBook Pro / macOS 26 / Terminal.app）で自分が使うためだけに作っていて、
> 他の環境での動作確認やサポートはしていません。非公開 API と Claude Code の非公式な内部ファイルに依存しているので、
> OS や Claude Code の更新で予告なく壊れます。参考にしたり持っていったりするのは自由ですが、自己責任でどうぞ。
> Touch Bar 上の表示は好みで英語にしています。

```
Control Strip:   26%        緑 = アイドル · オレンジ = 実行中のセッションあり · 赤 = 5時間制限が 90% 以上
                 ●26%       青緑の点 = スリープ禁止中（remote-control が on のセッションがある）

一覧ビュー:      5h 26% ↻ 1h12    ● my-app ⎇ main*  Fix login bug        ● notes  Thesis outline          remote-control
                 7d 23% ↻ 5d12h     RUN 3m · ctx 13% · sh×1 · RC           IDLE 12m · ctx 37%                     ● 1/2 on

詳細ビュー:      ‹ all   ● ~/src/my-app            ● $ npm run dev    ⎇ main*         ctx 13%          fable-5.1 …   remote-control
                           RUN 3m · pid 73776 · ttys004  shell · 2m   Fix login bug   153k / 1M tok    effort high …   ● on · session_01…
```

- **Control Strip の項目** – 5時間レート制限の使用率を常時表示。色で状態がわかります。
- **一覧ビュー**（項目をタップ） – レート制限とリセットまでの残り時間、稼働中のセッションごとに1セル
  （ディレクトリ、git ブランチ、セッション名、RUN/IDLE の経過時間、コンテキスト使用率、実行中のシェルコマンド数、remote-control）。
- **詳細ビュー** – セッションをタップすると、その Terminal タブが前面に出て、そのセッションの情報を全部表示します：
  パス、pid/tty、実行中の Bash ツールのコマンド、コンテキストのトークン数、model/effort/fast/thinking、変更行数、
  稼働時間/API 時間/コスト、プロンプトキャッシュの TTL とヒット率、バージョン、remote-control の状態。
- **その場で説明** – 詳細ビューのセルをタップすると、日本語の説明と関連するスラッシュコマンド
  （`/model`、`/fast`、`/config`、`/context`、`/compact`、`/usage`、`/status`、`/remote-control`）が出ます。コマンドをタップすると
  そのセッションの Terminal タブに入力されます。`/compact` だけは2回タップが必要です。
- **自動追従** – Claude Code が動いている Terminal タブが最前面のあいだは、そのセッションを自動で表示します。
- **remote-control 中はスリープしない** – remote-control が on のセッションが1つでもあるあいだ、`pmset disablesleep 1` で
  システムのスリープを止めます（蓋を閉じても動き続けるので、外出先のスマホから続きを操作できます）。全部 off になるか
  セッションが終われば元に戻ります。有効なあいだは Control Strip に青緑の点、remote-control セルに `awake` が出ます。
  いま見ているセッションが off でも、他のセッションが on なら青緑の点と `off · +1 · awake`（他に 1 セッションが on）で理由がわかります。
  電池を節約したいときは、remote-control セルをタップして `allow sleep` を押すと、蓋を閉じたら普通にスリープするようになります
  （蓋を開けているあいだの放置スリープは引き続き止めます）。このあいだは `on · sleep` と表示され、青緑の点は消えます。
  `keep awake` を押すか、電源アダプタをつなぐと元に戻ります。
  バッテリー駆動で残量 15% 以下になったら解除します（`batt`）。アプリ終了時も必ず元に戻します。
  この設定はアプリが完全に管理します：on のセッションがなければ、手動で `pmset disablesleep 1` にしていても 0 に戻します
  （戻し忘れたままカバンの中で動き続ける事故を防ぐため）。
  以前は [Capsomnia](https://github.com/fuji-mak/capsomnia)（Caps Lock 連動）でやっていたことの置き換えです。
- **remote-control をまとめて切り替え** – remote-control セルをタップすると `all on` / `all off` が出ます。
  まだ off のセッション全部で `/remote-control` を実行、または on のセッション全部を切断します。切断は Claude Code の
  メニュー（Disconnect this session / Continue）を自動で操作していて、メニューが画面に出たのを確認してから選びます。
  確認ダイアログなどを表示中のセッションは飛ばします（`touchbar.log` に記録）。
- **音声入力** – マイクのボタンで、そのセッションの Claude Code 内蔵の音声入力（`/voice`）を始めます。もう一度押すと
  話した内容を送信、`✕` で破棄。文字起こしは Claude Code 側（Anthropic のサーバー）が行うので、精度も言語設定も
  Claude Code のものです。詳細ビューではそのセッション、一覧ビューではセッションが1つだけのときに出ます。
  押すとそのタブを前面に出して Space（開始・送信）や Esc（破棄）のキーを送るだけなので、キーボードで Space を押すのと同じ動きです。
  録音中はボタンが赤くなります。入力欄に書きかけの文があると始まりません（Claude Code の仕様）。
- **他アプリの Touch Bar を置き換え** – `apps.txt` に書いたアプリ（初期値は Safari・Chrome・Finder）が最前面のあいだは、
  そのアプリのコントロールの代わりに一覧ビューを表示します。ファイルを編集するだけで追加・削除でき、再ビルドは不要です。

## 負荷

通信なし、子プロセスの起動も基本なし（例外はスリープ禁止の切り替え時に `pmset` を1回呼ぶだけ）。小さな JSON ファイルをいくつか読み、プロセス情報はカーネル（`sysctl`）に直接問い合わせます。
頻度は、バーが見えているか Terminal が前面のときは 2 秒ごと、それ以外は 10 秒ごと。
プロセステーブルの走査はバーが見えているあいだだけです。実測で CPU 約 0%、RSS 約 60 MB。

## 必要なもの

- Touch Bar 付きの MacBook Pro、macOS 15 以降（開発は macOS 26）、Xcode Command Line Tools（`swiftc`）
- Terminal.app（タブの検出とフォーカスに AppleScript インターフェースを使用）
- statusline スクリプトを設定済みの Claude Code と `jq`

## インストール

```sh
git clone https://github.com/KaiTabata/claude-touchbar.git ~/.config/claude-touchbar
cd ~/.config/claude-touchbar
./install.sh        # ClaudeTouchBar.app をビルドし、KeepAlive の LaunchAgent を登録
./install-awake.sh  # 任意：remote-control 中のスリープ禁止を使う場合（管理者パスワードを1回聞かれます）
```

`install-awake.sh` は `/etc/sudoers.d/claude-touchbar` を作り、`pmset -a disablesleep 0` と `pmset -a disablesleep 1` の
2コマンドだけをパスワードなしの sudo で実行できるようにします（この設定の変更には root が必要なため）。入れなければ
スリープ禁止は働かず、remote-control セルに `sudo✗` と出るだけです。

そのあと `statusline-snippet.sh` の中身を自分の statusline スクリプトに貼り付けます。Claude Code がコンテキスト・モデル・
コスト・レート制限のデータを渡してくれるのは statusline だけなので、アプリはそこ経由でデータを受け取ります。

初回は macOS が「ClaudeTouchBar が Terminal を制御することを許可するか」を聞いてくるので許可してください。再ビルドすると
ad-hoc 署名が変わるため、`./build.sh` のたびにこのダイアログがまた出ます。

音声入力を使う場合は、さらに次の準備が要ります。

- どれかのセッションで `/voice tap` を1回実行（タップで開始・タップで送信のモード。設定に保存され、全セッションに効きます。
  キーボードでも、入力欄が空のときに Space で始まるようになります）。
- 認識言語は Claude Code の `language` 設定に従います。日本語なら `~/.claude/settings.json` に `"language": "japanese"`。
- システム設定 › プライバシーとセキュリティ › アクセシビリティ で ClaudeTouchBar を許可（キーを送るため）。
  マイクのボタンを初めて押したときに案内が出ます。再ビルドすると署名が変わるので、一度リストから削除して許可し直してください。
- Terminal にマイクの使用を許可（録音するのは Terminal 内の Claude Code です）。

アンインストール：

```sh
launchctl bootout gui/$(id -u)/space.tabataba.claude-touchbar
rm ~/Library/LaunchAgents/space.tabataba.claude-touchbar.plist
sudo rm -f /etc/sudoers.d/claude-touchbar
```

## 仕組みと注意点

- システム全体に出す Touch Bar 用の公開 API はありません。MTMR や Pock と同じ非公開 API
  （`DFRElementSetControlStripPresenceForIdentifier`、`+[NSTouchBarItem addSystemTrayItem:]`、
  `+[NSTouchBar presentSystemModalTouchBar:…]`）を使っています。macOS の更新で壊れる可能性があります。おかしいときは `touchbar.log` を確認。
- Control Strip はサードパーティの項目を黙って落とすので、数秒ごとに登録をし直し、スリープ復帰時・ControlStrip の再起動時・
  バーを閉じたあとにも入れ直しています。
- セッション情報は Claude Code の非公式なファイル（`~/.claude/sessions/<pid>.json`）から取っています。remote-control は
  `bridgeSessionId` があればオンとみなします。実行中のシェルコマンドは、claude プロセスの子プロセスのうち引数が
  `~/.claude/shell-snapshots/` を参照しているものです。どれもバージョンが変わると変わる可能性があります。
- 音声入力と remote-control の一括切り替えは、Terminal タブの画面の文字（`REC · tap to send`、`Disconnect this session`、
  入力欄の罫線）を読んで状態を判断しています。Claude Code の表示が変わると動かなくなります。
- コマンドラインからも実行できます（動作確認用）：`ClaudeTouchBar.app/Contents/MacOS/ClaudeTouchBar --rc-all on|off [pid]`、
  `--voice <pid> toggle|cancel`。
- セッションのタイトルは Claude Code のセッション名です。`/rename <name>` で変更するか、`claude -n <name>` で起動します。

## ライセンス

[MIT](LICENSE)
