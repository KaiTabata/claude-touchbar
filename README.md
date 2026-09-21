# claude-touchbar

Touch Bar 付き MacBook で、[Claude Code](https://claude.com/claude-code) のセッション状況を Touch Bar に表示する小さなアプリです。

> **これは自分用に作ったものです。** 自分の環境（M2 MacBook Pro / macOS 26 / Terminal.app）で自分が使うためだけに作っていて、
> 他の環境での動作確認やサポートはしていません。非公開 API と Claude Code の非公式な内部ファイルに依存しているので、
> OS や Claude Code の更新で予告なく壊れます。参考にしたり持っていったりするのは自由ですが、自己責任でどうぞ。
> Touch Bar 上の表示は好みで英語にしています。

```
Control Strip:   26%        緑 = アイドル · オレンジ = 実行中のセッションあり · 赤 = 5時間制限が 90% 以上

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
- **他アプリの Touch Bar を置き換え** – `apps.txt` に書いたアプリ（初期値は Safari・Chrome・Finder）が最前面のあいだは、
  そのアプリのコントロールの代わりに一覧ビューを表示します。ファイルを編集するだけで追加・削除でき、再ビルドは不要です。

## 負荷

子プロセスの起動なし、通信なし。小さな JSON ファイルをいくつか読み、プロセス情報はカーネル（`sysctl`）に直接問い合わせます。
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
```

そのあと `statusline-snippet.sh` の中身を自分の statusline スクリプトに貼り付けます。Claude Code がコンテキスト・モデル・
コスト・レート制限のデータを渡してくれるのは statusline だけなので、アプリはそこ経由でデータを受け取ります。

初回は macOS が「ClaudeTouchBar が Terminal を制御することを許可するか」を聞いてくるので許可してください。再ビルドすると
ad-hoc 署名が変わるため、`./build.sh` のたびにこのダイアログがまた出ます。

アンインストール：

```sh
launchctl bootout gui/$(id -u)/space.tabataba.claude-touchbar
rm ~/Library/LaunchAgents/space.tabataba.claude-touchbar.plist
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
- セッションのタイトルは Claude Code のセッション名です。`/rename <name>` で変更するか、`claude -n <name>` で起動します。
