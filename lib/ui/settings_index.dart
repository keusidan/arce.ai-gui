import '../core/settings_search.dart';
import '../services/app_controller.dart' show SettingsSection;

/// The titles of the groups of the settings screen (the same words as the group list there).
String settingsSectionTitle(SettingsSection section) => switch (section) {
      SettingsSection.providers => 'オンライン接続（プロバイダ）',
      SettingsSection.online => 'オンラインモデルの設定',
      SettingsSection.local => 'ローカルモデルの設定',
      SettingsSection.coding => '分担モード',
      SettingsSection.shell => 'Linux 環境',
      SettingsSection.limits => '上限とタイムアウト',
      SettingsSection.mcp => 'MCP サーバー',
      SettingsSection.basic => 'モデル全般設定',
      SettingsSection.search => '検索設定',
      SettingsSection.display => '表示・プライバシー',
      SettingsSection.update => 'アップデート',
      SettingsSection.reports => 'エラーの報告',
    };

SettingsSearchEntry _group(SettingsSection section, String subtitle, List<String> keywords) => SettingsSearchEntry(
      sectionId: section.name,
      title: settingsSectionTitle(section),
      subtitle: subtitle,
      keywords: keywords,
      isGroup: true,
    );

SettingsSearchEntry _row(SettingsSection section, String title, {String subtitle = '', List<String> keywords = const [], String? key}) =>
    SettingsSearchEntry(sectionId: section.name, title: title, subtitle: subtitle, keywords: keywords, settingKey: key);

/// Everything the settings screen has, as search entries: one for each group, and one for each row,
/// switch, value, card and button in it, with the words a person would type for it.
///
/// The titles and notes are the ones shown on the screen. A row whose note changes with the state
/// (the Linux environment's size, whether the error report can be sent) has the fixed part, or none.
/// The group of an entry is where it is opened from: the model list, fallback and token-check rows of
/// the model detail page are in [SettingsSection.providers] (its 「詳細」 button).
///
/// Keep it in step with the screen: `test/ui/settings_index_test.dart` checks that every setting the
/// chat can change has an entry, and that every key an entry names exists.
final List<SettingsSearchEntry> settingsIndex = [
  // ------------------------------------------------------------------ the groups
  _group(SettingsSection.providers, 'API の接続先と、使うモデル', ['プロバイダ', 'provider', 'openai', 'groq', 'openrouter', 'ollama', 'api', 'キー', 'key', 'モデル', 'オンライン', '接続']),
  _group(SettingsSection.online, 'temperature・最大トークン・追加プロンプト', ['online', 'オンライン', 'temperature', 'クラウド', 'cloud']),
  _group(SettingsSection.local, 'サンプリング・コンテキスト長・スレッド・GPU', ['local', 'ローカル', 'ローカルモデル', 'llama', 'gguf', 'メモリ', 'kv', 'キャッシュ', 'cache']),
  _group(SettingsSection.coding, 'plan が設計と分担数を決め、coding が調べてから実装する', ['coding', '分担', 'planner', 'developer', 'delegate', '並列', 'コード']),
  _group(SettingsSection.shell, 'コマンドを動かす（Android は内蔵の Ubuntu、PC はコンテナか PC 全体）', ['linux', 'ubuntu', 'proot', 'shell', 'コマンド', 'ターミナル', 'terminal', 'run_command', 'opencode', 'agy', 'antigravity', 'セッション', '対話', '秘密', '環境変数', 'workspace']),
  _group(SettingsSection.limits, '添付・検索・通信・更新の上限と待ち時間', ['limit', 'timeout', 'タイムアウト', '上限', '制限', '待ち時間', '添付', '要約', '圧縮', 'compaction']),
  _group(SettingsSection.mcp, '外部の道具（GitHub など）をつなぐ', ['mcp', 'github', 'tool', '道具', 'ツール', 'サーバー', 'token', 'トークン', 'kaggle']),
  _group(SettingsSection.basic, 'ローカルとオンライン共通：思考・回答・最大トークン・再試行', ['thinking', '思考', '回答', '口調', 'タイトル', 'エージェント', 'agent', 'retry', '再試行']),
  _group(SettingsSection.search, '検索サーバー・検索 API・結果の件数', ['search', 'searxng', 'brave', 'tavily', 'exa', 'serper', 'web検索', 'ウェブ検索', 'api']),
  _group(SettingsSection.display, 'テーマ・思考中のアイコン', ['通知', 'notification', 'notify', 'テーマ', 'theme', 'dark', 'ダーク', '文字', 'フォント', 'font', 'プライバシー', 'privacy']),
  _group(SettingsSection.update, '自動で更新する・確認の間隔', ['update', 'アップデート', 'バージョン', 'version', 'リリース', 'release', 'インストール', 'ダウンロード']),
  _group(SettingsSection.reports, 'エラーを GitHub の issue に自動で送る（トークンを入れたときだけ）', ['error', 'エラー', 'issue', '報告', 'レポート', 'report', 'クラッシュ', 'crash', 'token', 'トークン']),

  // ------------------------------------------------------------------ providers (and the model detail page)
  _row(SettingsSection.providers, 'ローカルモデル', subtitle: 'この端末の中だけで動きます（外部に送りません）', keywords: ['local', 'ローカル', 'オフライン', 'offline', '切り替え']),
  _row(SettingsSection.providers, 'プロバイダを追加', keywords: ['provider', 'add', '追加', '接続先', 'openai', 'groq', 'openrouter', 'ollama', 'lm studio']),
  _row(SettingsSection.providers, '詳細', subtitle: 'モデル一覧の自動取得・フォールバック・送る前のトークン長のチェック', keywords: ['モデルの詳細設定', 'detail', 'fallback', 'フォールバック']),
  _row(SettingsSection.providers, 'Cloudflare AI Gateway', subtitle: 'Cloudflare のアカウント 1 つで、OpenAI・Anthropic・Google・xAI・Workers AI などのモデルを呼べます（「プロバイダを追加」で選ぶ）', keywords: ['cloudflare', 'gateway', 'ai gateway', 'workers ai', 'まとめる', 'unified billing', 'クラウドフレア']),
  _row(SettingsSection.providers, 'Base URL', subtitle: 'Base URL は /chat/completions より前までです。', keywords: ['url', 'アドレス', 'エンドポイント', 'endpoint', 'openai 互換']),
  _row(SettingsSection.providers, 'APIキー', subtitle: 'sk-…（端末の安全な領域に保存します）', keywords: ['api key', 'key', 'キー', 'token', 'トークン', '秘密', 'secret']),
  _row(SettingsSection.providers, 'ツール呼び出しに対応', subtitle: '検索や設定の変更などを、モデルが自分で呼べるようにします。対応しないモデルではオフに', keywords: ['function calling', 'tools', 'ツール', '道具']),
  _row(SettingsSection.providers, 'モデル一覧を自動で取得', subtitle: '保存したときと、一覧が古くなったときに、提供元の /models を読みます。一覧を返さない提供元ではオフに', keywords: ['models', '/models', '一覧']),
  _row(SettingsSection.providers, '追加ヘッダー（JSON・任意）', keywords: ['header', 'headers', 'ヘッダー', 'http', 'json']),
  _row(SettingsSection.providers, '追加のリクエスト項目（JSON・任意）', keywords: ['body', 'リクエスト', 'json', 'reasoning_effort', 'prompt_cache_key', 'キャッシュ']),
  _row(SettingsSection.providers, 'モデルを追加', keywords: ['model', 'モデル名', 'add']),
  _row(SettingsSection.providers, 'コンテキスト長（入力と出力の合計）', keywords: ['context', 'コンテキスト', '文脈', 'トークン', 'token']),
  _row(SettingsSection.providers, '最大出力の上限（モデルが返せる最大。最大トークンはこれに収めます）', keywords: ['max output', '最大出力', 'トークン']),
  _row(SettingsSection.providers, '思考の送り方', subtitle: '提供元によって項目の名前が違うので、送り方を選びます。', keywords: ['thinking', '思考', '推論', 'reasoning', 'deepseek', 'glm', 'gemini']),
  _row(SettingsSection.providers, '推論の強さ', subtitle: 'low / high / max、または 1〜100。空欄は速度⇔精度から決めます', keywords: ['reasoning effort', 'effort', '思考', '強さ']),
  _row(SettingsSection.providers, '過去の思考を返す', keywords: ['reasoning_content', 'replay', '思考', 'deepseek', 'glm']),
  _row(SettingsSection.providers, 'おすすめの送り方を入れる', keywords: ['thinking', '思考', 'おすすめ', '推奨']),
  _row(SettingsSection.providers, '画像を送る', subtitle: '添付した画像を画像のまま送ります。対応していないモデルでは、オフのままにしてください', keywords: ['vision', '画像', '添付', 'image']),
  _row(SettingsSection.providers, '上限を取得', keywords: ['fetch', 'コンテキスト', 'hugging face', '調べる']),
  _row(SettingsSection.providers, '自動で取得する', subtitle: 'オフにすると、「更新」を押したときだけ読み込みます', keywords: ['モデル一覧', 'models', '自動取得', 'model list'], key: 'modelListAutoFetch'),
  _row(SettingsSection.providers, '取り直す間隔', subtitle: '一覧がこの時間より古いとき、起動したときに読み直します', keywords: ['モデル一覧', '更新', 'refresh', '時間'], key: 'modelListRefreshHours'),
  _row(SettingsSection.providers, '覚える数', subtitle: 'モデルの一覧と、分担モードの選択画面の先頭に、最近使った順で出します（0 でなし）', keywords: ['最近', 'recent', '履歴', '履歴を消す'], key: 'recentModelCount'),
  _row(SettingsSection.providers, 'フォールバックを使う', subtitle: 'オフにすると、ルールは残したまま、切り替えません', keywords: ['fallback', '代わり', '403', '429', '5xx', '切り替え', 'ルール'], key: 'fallbackEnabled'),
  _row(SettingsSection.providers, 'ルールを追加', keywords: ['fallback', 'フォールバック', 'どのモデルが使えないとき', '代わりに使うモデル']),
  _row(SettingsSection.providers, '送る前にチェックする', keywords: ['token', 'トークン', 'precheck', '事前', '文脈', 'コンテキスト', 'エラー'], key: 'tokenPrecheck'),
  _row(SettingsSection.providers, '指示とツール定義に使ってよい割合', subtitle: 'これを超えると、送らずにエラーにします', keywords: ['overhead', 'トークン', 'ツール定義', '割合', 'mcp'], key: 'tokenOverheadPercent'),
  _row(SettingsSection.providers, 'MCP サーバーのツール定義の大きさ', subtitle: '有効なサーバーに聞いて、毎回の送信に足されるトークン数を調べます', keywords: ['mcp', 'ツール定義', 'トークン', '調べる']),

  // ------------------------------------------------------------------ online model
  _row(SettingsSection.online, 'temperature', subtitle: '大きいほど表現がばらつきます（0〜2）', keywords: ['温度', '創造性', 'ランダム', 'online', 'オンライン'], key: 'onlineTemperature'),
  _row(SettingsSection.online, 'top_p', subtitle: '選ぶ言葉の範囲（0〜1）', keywords: ['top p', 'nucleus', 'online', 'オンライン'], key: 'onlineTopP'),
  _row(SettingsSection.online, '最大トークン', subtitle: '1回の返信の長さの基準（思考の分も含みます）。空欄は、モデルの推奨か共通の値', keywords: ['max tokens', 'max_tokens', '返信の長さ', 'online', 'オンライン'], key: 'onlineMaxTokens'),
  _row(SettingsSection.online, 'モデルごとの最大出力を使う', subtitle: '最大トークンが空欄のとき、そのモデルが返せる最大の長さ（提供元の一覧から取得）で頼みます。取得できなければ共通の値です', keywords: ['max output', '最大出力', 'モデルごと', 'gemini', 'トークン', 'online', 'オンライン'], key: 'onlineUseModelMax'),
  _row(SettingsSection.online, '追加プロンプト', subtitle: 'オンラインモデルにだけ送る指示（2000文字まで）', keywords: ['prompt', 'system prompt', '指示', 'プロンプト', 'online', 'オンライン'], key: 'onlinePrompt'),
  _row(SettingsSection.online, 'モデルの上限を自動で調べる', subtitle: '使い始めたモデルのコンテキスト長・最大出力・画像対応を、提供元のモデル一覧から調べて保存します', keywords: ['model info', 'コンテキスト', '文脈', '上限', '自動'], key: 'autoFetchModelInfo'),
  _row(SettingsSection.online, 'Hugging Face からも調べる', subtitle: '提供元が上限を返さないとき、モデル名（owner/name）だけを huggingface.co に送って、コンテキスト長を読みます', keywords: ['huggingface', 'hf', 'コンテキスト', 'プライバシー'], key: 'fetchModelInfoFromHub'),

  // ------------------------------------------------------------------ local model
  _row(SettingsSection.local, 'temperature', subtitle: '大きいほど表現がばらつきます（0〜2）', keywords: ['温度', '創造性', 'ランダム', 'local', 'ローカル'], key: 'localTemperature'),
  _row(SettingsSection.local, 'top_p', subtitle: '選ぶ言葉の範囲（0〜1）', keywords: ['top p', 'nucleus', 'local', 'ローカル'], key: 'localTopP'),
  _row(SettingsSection.local, 'top_k', subtitle: '候補にする言葉の数（0 は既定）', keywords: ['top k', 'local', 'ローカル'], key: 'localTopK'),
  _row(SettingsSection.local, 'min_p', subtitle: '確率がこれ未満の言葉を除きます（0〜1）', keywords: ['min p', 'local', 'ローカル'], key: 'localMinP'),
  _row(SettingsSection.local, 'DRY（繰り返しの抑制）', subtitle: '大きいほど、同じ言い回しの繰り返しを避けます（0 でオフ）', keywords: ['dry', '繰り返し', 'repetition', 'penalty', 'ペナルティ'], key: 'localDryMultiplier'),
  _row(SettingsSection.local, '最大トークン', subtitle: '1回の返信の長さの基準。空欄は共通の値', keywords: ['max tokens', 'max_tokens', '返信の長さ', 'local', 'ローカル'], key: 'localMaxTokens'),
  _row(SettingsSection.local, '追加プロンプト', subtitle: 'ローカルモデルにだけ送る指示（2000文字まで）', keywords: ['prompt', 'system prompt', '指示', 'プロンプト', 'local', 'ローカル'], key: 'localPrompt'),
  _row(SettingsSection.local, 'Context Length', subtitle: 'モデルが一度に扱う長さ。大きいほどメモリを使います', keywords: ['コンテキスト長', 'コンテキスト', '文脈', 'n_ctx', 'メモリ', 'ram'], key: 'contextLength'),
  _row(SettingsSection.local, 'CPU Threads', subtitle: 'Auto は端末のコア数から決めます', keywords: ['スレッド', 'thread', 'cpu', 'コア'], key: 'threads'),
  _row(SettingsSection.local, 'HyperLoad', subtitle: 'CPUを使い切って高速化します（発熱・消費電力が増えます）', keywords: ['高速', '発熱', 'cpu', '消費電力', 'バッテリー'], key: 'hyperLoad'),
  _row(SettingsSection.local, 'GPU オフロード', subtitle: 'GPU に任せる量（対応する端末のみ）', keywords: ['gpu', 'opencl', 'npu', 'オフロード', 'offload'], key: 'gpuOffload'),
  _row(SettingsSection.local, 'KV キャッシュ', subtitle: 'Q8_0 でメモリが約半分、Q4_0 で約3分の1。小さいほど精度は少し落ちます', keywords: ['kv', 'cache', 'キャッシュ', 'q8_0', 'q4_0', 'f16', 'メモリ', '量子化'], key: 'kvCache'),
  _row(SettingsSection.local, 'KV キャッシュをファイルに保存', subtitle: '会話の途中までの計算結果を保存し、開き直したときの待ち時間を省きます（Android の llama.cpp のみ。1つの会話で数百MBになることがあります）', keywords: ['kv', 'cache', 'キャッシュ', '保存', 'スナップショット', 'snapshot', '高速'], key: 'kvSnapshotEnabled'),
  _row(SettingsSection.local, '保存の上限（合計）', subtitle: '超えたら、いちばん長く使っていない会話の分から消します', keywords: ['kv', 'キャッシュ', '容量', 'mb', 'ストレージ'], key: 'kvSnapshotMaxMb'),
  _row(SettingsSection.local, '保存する最小の長さ', subtitle: 'これより短いプロンプトは、計算し直すほうが速いので保存しません', keywords: ['kv', 'キャッシュ', 'トークン'], key: 'kvSnapshotMinTokens'),
  _row(SettingsSection.local, '保存済みのキャッシュ', keywords: ['kv', 'キャッシュ', 'すべて削除', '削除', '容量']),
  _row(SettingsSection.local, 'Force Execution', subtitle: 'メモリ不足の警告があっても、モデルの選択を許可します', keywords: ['強制', 'メモリ不足', '警告', 'force'], key: 'forceExecution'),
  _row(SettingsSection.local, 'Linux 環境（試験）：proot の確認', subtitle: 'アプリに入れた proot を 1 回起動して、この端末で動くかを確かめます（何も変更しません）', keywords: ['proot', 'linux', 'ubuntu', '確かめる', '確認']),

  // ------------------------------------------------------------------ coding mode
  _row(SettingsSection.coding, '分担モード', subtitle: 'plan が設計と分担数を決め、coding が担当を調べてから実装します', keywords: ['coding', '分担', 'planner', 'developer', 'delegate', '並列'], key: 'codingPlanEnabled'),
  _row(SettingsSection.coding, 'plan は、使用中のモデルに合わせる', subtitle: 'オン：入力欄で選んだモデルが plan になります（切り替えると、コーディングの依頼もそのモデルで答えます）。オフ：下で決めたモデルに固定します', keywords: ['planner', 'plan', '固定', 'モデル切り替え'], key: 'codingPlannerFollows'),
  _row(SettingsSection.coding, 'plan のモデル', subtitle: 'あなたに答え、仕事を分けて渡し、結果を確認します（高性能なモデル向き）', keywords: ['planner', 'モデル'], key: 'plannerModel'),
  _row(SettingsSection.coding, 'coding のモデル', subtitle: 'コードを書きます（安いモデル・ローカルモデル向き）', keywords: ['developer', 'モデル', '安い'], key: 'developerModel'),
  _row(SettingsSection.coding, 'coding のモデルを追加', subtitle: '右で選ぶと、coding が増えます（安いモデルを並べると速くなります）', keywords: ['developer', 'coding の追加モデル', '並列', 'モデル'], key: 'developerModelsMore'),
  _row(SettingsSection.coding, 'タスクの最大数', subtitle: 'plan が 1 回の依頼に入れてよい仕事の数（超えた分は断ります）', keywords: ['task', 'タスク', '仕事', '数'], key: 'codingMaxTasks'),
  _row(SettingsSection.coding, '1 つの coding が同時に走らせる数', subtitle: 'coding が何個の仕事を同時に受けるか（ローカルモデルは常に1）。coding が複数あれば、その合計だけ同時に走ります', keywords: ['parallel', '並列', '同時', '並行'], key: 'codingParallel'),
  _row(SettingsSection.coding, '分担数の上限', subtitle: '同時に動く担当の数の上限。plan はこの中で分担数を決め、足りなければ増やす提案をします', keywords: ['workers', '分担数', '並列', '同時', '担当'], key: 'codingMaxWorkers'),
  _row(SettingsSection.coding, '先に調べて、確認してから実装する', subtitle: 'オン：coding が担当を調べてレポートを返し、全部そろったら plan がまとめてあなたに見せます。OK が出るまで実装しません。オフ：すぐに実装します', keywords: ['investigate', '調査', 'レポート', '確認', '承認', '設計'], key: 'codingInvestigateFirst'),
  _row(SettingsSection.coding, 'レビューの回数', subtitle: 'plan が直しを指示してよい回数（plan への指示に書きます）。0 なら直させません', keywords: ['review', 'レビュー', '直し', 'revise'], key: 'codingReviewRounds'),
  _row(SettingsSection.coding, 'plan が読む結果の長さ', subtitle: 'coding の結果を、plan に渡す文字数（1 件ごと。あなたには全部見せます）', keywords: ['result', '結果', '文字数'], key: 'codingResultChars'),
  _row(SettingsSection.coding, 'coding の最大トークン', subtitle: '1つのタスクのコードの長さ（思考の分も含みます）。自動は、モデルの推奨と上限に合わせます', keywords: ['max tokens', 'トークン', 'コード', '長さ'], key: 'codingDeveloperMaxTokens'),

  // ------------------------------------------------------------------ Linux environment
  _row(SettingsSection.shell, 'コマンド実行を使う', subtitle: 'オフにすると、モデルに run_command を渡しません', keywords: ['run_command', 'shell', 'コマンド', 'linux', 'proot'], key: 'shellEnabled'),
  _row(SettingsSection.shell, 'サンドボックス化する', subtitle: 'PC：オンならコマンドを Docker か Podman のコンテナの中で、オフなら PC の上であなたの権限のまま動かします', keywords: ['sandbox', 'サンドボックス', 'docker', 'podman', 'コンテナ', 'container', 'pc', 'パソコン', '全体', 'アクセス']),
  _row(SettingsSection.shell, '実行前の確認', subtitle: 'PC でサンドボックス化しないとき：自動（危険な操作は止める）・毎回確認・確認しない', keywords: ['approval', '承認', '確認', '自動', '危険', 'pc']),
  _row(SettingsSection.shell, '危険な操作の一覧', subtitle: '自動のとき止めるコマンドの正規表現（1 行に 1 つ）', keywords: ['danger', '危険', '正規表現', 'regex', 'rm -rf', 'format', 'shutdown']),
  _row(SettingsSection.shell, 'コマンドを渡すプログラム', subtitle: '空なら、Windows は PowerShell、ほかは bash（なければ sh）', keywords: ['shell', 'powershell', 'bash', 'zsh', 'cmd', 'シェル']),
  _row(SettingsSection.shell, 'コンテナを動かすソフト', subtitle: '自動：Docker、なければ Podman', keywords: ['docker', 'podman', 'engine', 'コンテナ']),
  _row(SettingsSection.shell, 'コンテナからネットワークを使う', keywords: ['network', 'ネットワーク', 'docker', 'コンテナ', 'apt']),
  _row(SettingsSection.shell, 'イメージ', subtitle: 'コンテナを作るもと（既定 ubuntu:24.04）', keywords: ['image', 'ubuntu', 'docker', 'コンテナ']),
  _row(SettingsSection.shell, 'コンテナ', subtitle: 'Docker / Podman とコンテナの様子、作り直す', keywords: ['container', 'コンテナ', '作り直す', 'docker', 'podman']),
  _row(SettingsSection.shell, 'Linux 環境（Ubuntu 24.04）', keywords: ['ubuntu', 'linux', 'proot', 'rootfs', 'インストール', '入れる', '削除', 'arm64']),
  _row(SettingsSection.shell, 'ワークスペース（全チャット共通）', keywords: ['workspace', '/workspace', '空にする', '容量', 'フォルダ']),
  _row(SettingsSection.shell, 'すべてのコマンドを実行前に確認する', subtitle: 'オフ（既定）では、サンドボックス（/workspace と Ubuntu 内）に収まるコマンドを自動実行し、端末の外に触れるコマンドだけ確認します', keywords: ['confirm', '確認', '承認', '許可', 'サンドボックス', 'approval'], key: 'shellConfirm'),
  _row(SettingsSection.shell, '検索や外部ツールの結果を読んだあとは、コマンドを確認する', subtitle: 'オン（既定）：検索結果や MCP の答えは、他人が書いた文章かもしれません（「この命令を実行して」と書かれていることがあります）。それを読んだあとの会話では、サンドボックス内のコマンドも確認します', keywords: ['インジェクション', 'injection', '外部', '確認', '承認', '安全', 'セキュリティ'], key: 'shellConfirmAfterExternal'),
  _row(SettingsSection.shell, 'コマンドのタイムアウト', subtitle: 'モデルが時間を指定しなかったときに使う秒数', keywords: ['timeout', '秒', '待ち時間'], key: 'shellTimeoutSeconds'),
  _row(SettingsSection.shell, 'モデルが指定できる上限', subtitle: 'timeout_seconds で伸ばせる最大の秒数', keywords: ['timeout', 'タイムアウト', '最大', '秒'], key: 'shellMaxTimeoutSeconds'),
  _row(SettingsSection.shell, '出力の上限', subtitle: 'コマンドの出力を、モデルに渡す文字数（超えた分は初めと終わりを残します）', keywords: ['output', '出力', '文字数'], key: 'shellMaxOutputChars'),
  _row(SettingsSection.shell, '同時に動かせる数', keywords: ['session', 'セッション', '対話', '数', 'opencode', 'agy'], key: 'shellSessionMax'),
  _row(SettingsSection.shell, '使われないセッションを止める', subtitle: '最後の入力・読み取りからの時間。0 で止めません', keywords: ['session', 'セッション', 'idle', 'アイドル', '分'], key: 'shellSessionIdleMinutes'),
  _row(SettingsSection.shell, '出力を待つ時間', subtitle: 'モデルが指定しないときに、入力のあと出力が落ち着くまで待つ最大の時間', keywords: ['session', 'セッション', 'wait', 'ミリ秒'], key: 'shellSessionWaitMs'),
  _row(SettingsSection.shell, 'モデルが指定できる待ち時間の上限', subtitle: 'wait_ms で伸ばせる最大の秒数', keywords: ['session', 'セッション', 'wait_ms', '秒'], key: 'shellSessionMaxWaitSeconds'),
  _row(SettingsSection.shell, '端末の幅', keywords: ['session', 'セッション', 'terminal', 'cols', '桁'], key: 'shellSessionCols'),
  _row(SettingsSection.shell, '端末の高さ', keywords: ['session', 'セッション', 'terminal', 'rows', '行'], key: 'shellSessionRows'),
  _row(SettingsSection.shell, '画面から流れた行を残す数', subtitle: '次の読み取りで、流れた分もモデルに渡します', keywords: ['session', 'セッション', 'scrollback', 'スクロール', '行'], key: 'shellSessionScrollback'),
  _row(SettingsSection.shell, '読まれるまで残す出力', subtitle: 'これを超えて出力されると、古い分は失われます', keywords: ['session', 'セッション', 'buffer', 'バッファ', 'kb'], key: 'shellSessionBufferKb'),
  _row(SettingsSection.shell, 'ワークスペースの上限', subtitle: '全チャット共通の /workspace が、この大きさを超えて増えたらコマンドを止めます（rm で減らすコマンドは通ります）', keywords: ['workspace', '容量', 'mb', 'ストレージ', '制限'], key: 'workspaceLimitMb'),
  _row(SettingsSection.shell, '互換モード（seccomp を切る）', subtitle: 'この端末で proot が起動できないときだけ使います（PROOT_NO_SECCOMP=1）', keywords: ['compat', 'seccomp', 'proot', '起動できない', 'エラー'], key: 'shellCompatMode'),
  _row(SettingsSection.shell, '秘密（モデルが {{secret:ID}} で使う）', subtitle: 'GitHub のトークンなどを、コマンドの環境変数として渡せます（例：git push、gh、npm publish）。', keywords: ['secret', '秘密', '環境変数', 'env', 'token', 'トークン', 'github_token', 'gh_token', 'npm', 'api キー', 'git push', 'プレースホルダー', 'placeholder', 'id', 'ホスト', 'host', 'コマンドで使う秘密'], key: 'shellSecrets'),
  _row(SettingsSection.shell, '秘密を追加', keywords: ['secret', '秘密', '環境変数', 'env', 'token', 'トークン', '名前']),

  // ------------------------------------------------------------------ limits and timeouts
  _row(SettingsSection.limits, '添付できるファイルの数', subtitle: '1回のメッセージに付けられる数', keywords: ['attach', '添付', 'ファイル'], key: 'attachMaxFiles'),
  _row(SettingsSection.limits, 'ブラウザで開く試作ページを残す数', subtitle: '生成した HTML をブラウザで開く入口（アドレスは推測できない）。これを超えると古いものから消えます', keywords: ['preview', 'プレビュー', 'html', '試作', 'ページ'], key: 'previewMaxPages'),
  _row(SettingsSection.limits, 'show で一度に渡せるページの文字数', subtitle: 'モデルが道具 show に HTML・SVG を直接渡すときの最大の長さ。これより長いページは、ファイルに書いて、パスで見せます', keywords: ['show', 'ページ', 'html', '文字数', '上限'], key: 'showMaxChars'),
  _row(SettingsSection.limits, 'show で表示するフォルダから配るファイルの大きさ（MB）', subtitle: '/workspace のページの画像やスクリプトなどの 1 ファイルの上限。これを超えるファイルは配りません', keywords: ['show', 'ファイル', 'workspace', '上限', 'mb'], key: 'showMaxFileMb'),
  _row(SettingsSection.limits, '添付1ファイルから読む文字数', subtitle: 'これを超えた分は省略されます', keywords: ['attach', '添付', '文字数', 'ファイル'], key: 'attachCharsPerFile'),
  _row(SettingsSection.limits, '添付全体で読む文字数', subtitle: 'コンテキストを使い切らないための上限', keywords: ['attach', '添付', '文字数', 'コンテキスト'], key: 'attachTotalChars'),
  _row(SettingsSection.limits, '送る画像の大きさ', subtitle: '画像に対応するモデルへ送る1枚の上限', keywords: ['image', '画像', 'mb', 'サイズ'], key: 'attachImageMb'),
  _row(SettingsSection.limits, '検索・天気のタイムアウト', subtitle: 'この秒数で通信をあきらめます', keywords: ['timeout', 'タイムアウト', '検索', '天気', 'http', '通信'], key: 'httpTimeoutSeconds'),
  _row(SettingsSection.limits, 'MCPサーバーのタイムアウト', subtitle: '道具の呼び出しを待つ時間', keywords: ['mcp', 'timeout', 'タイムアウト', '道具'], key: 'mcpTimeoutSeconds'),
  _row(SettingsSection.limits, 'MCP の結果の上限', subtitle: 'MCP の道具の結果を、モデルに渡す文字数（超えた分は省きます。画像などのファイルは、中身ではなく説明を渡します）', keywords: ['mcp', '結果', '文字数', '上限'], key: 'mcpResultMaxChars'),
  _row(SettingsSection.limits, 'オンラインモデルの応答のタイムアウト', subtitle: '最初の応答までに待つ時間', keywords: ['timeout', 'タイムアウト', 'オンライン', '応答', 'provider'], key: 'providerTimeoutSeconds'),
  _row(SettingsSection.limits, 'ツールの繰り返しで止める回数', subtitle: '同じ道具を同じ引数で、この回数呼んだら、ループとみなして止めます（引数が違えば数えません）', keywords: ['loop', 'ループ', '繰り返し', 'ツール', '道具'], key: 'toolRepeatLimit'),
  _row(SettingsSection.limits, '長い会話を要約して、文脈に収める', subtitle: '文脈がいっぱいになる前に、古い道具の結果を切り詰め、それでも足りなければ、直近の発言より前をモデルに要約させます（新しい会話を始めなくて済みます）', keywords: ['compaction', '要約', '圧縮', 'チャット圧縮', 'コンテキスト', '文脈', '長い会話'], key: 'compactEnabled'),
  _row(SettingsSection.limits, '要約を始める文脈の使用率', subtitle: 'この割合を超えそうなときに、送る前に要約します（文脈の大きさが分かるモデルだけ）', keywords: ['compaction', '要約', '圧縮', '割合', '%', 'コンテキスト'], key: 'compactAtPercent'),
  _row(SettingsSection.limits, '要約せずに残す直近の発言', subtitle: 'あなたの直近の発言を、この数だけ（その後の返信も）そのまま残します', keywords: ['compaction', '要約', '圧縮', '直近'], key: 'compactKeepTurns'),
  _row(SettingsSection.limits, '要約の長さ', subtitle: '要約を、この文字数以内で書かせます', keywords: ['compaction', '要約', '圧縮', '文字数'], key: 'compactSummaryChars'),
  _row(SettingsSection.limits, '古い道具の結果の長さ', subtitle: '要約の前に、古い道具の結果をこの文字数まで切り詰めます', keywords: ['compaction', '要約', '圧縮', '道具', '結果', '切り詰め'], key: 'compactToolResultChars'),
  _row(SettingsSection.limits, 'ダウンロードの試行回数', subtitle: '通信が切れたとき、続きから取り直す回数（モデルも更新も）', keywords: ['download', 'ダウンロード', 'retry', '再試行', 'リトライ'], key: 'updateRetryAttempts'),
  _row(SettingsSection.limits, 'ダウンロードの無通信の判定', subtitle: 'この秒数なにも届かなければ、切れたとみなします', keywords: ['download', 'ダウンロード', 'stall', 'タイムアウト', '無通信'], key: 'updateStallSeconds'),
  _row(SettingsSection.limits, 'ダウンロードの同時接続数', subtitle: '大きなファイルを分けて同時に取ります。遅いときに増やします（1で分けない）', keywords: ['download', 'ダウンロード', '接続', '並列', '速度'], key: 'downloadConnections'),
  _row(SettingsSection.limits, '止まったダウンロードを次の起動で続ける', subtitle: 'アプリを閉じて止まったモデルのダウンロードを、起動したときに続きから取ります（モバイル回線でも始まります）', keywords: ['download', 'ダウンロード', '再開', 'resume', 'モデル', 'モバイル回線'], key: 'resumeDownloadsOnStart'),

  // ------------------------------------------------------------------ MCP servers
  _row(SettingsSection.mcp, 'MCP サーバーを追加', subtitle: 'Streamable HTTP の入口を登録します（例：https://api.githubcopilot.com/mcp/）。トークンは端末の安全な領域に保存します。', keywords: ['mcp', 'server', 'url', 'github', 'kaggle', '追加']),
  _row(SettingsSection.mcp, 'トークン', subtitle: 'Bearer で送ります（端末の安全な領域に保存）', keywords: ['token', 'bearer', 'mcp', 'キー', '秘密', 'pat']),
  _row(SettingsSection.mcp, 'このサーバーを使う', subtitle: 'オフの間は道具がチャットに出ません', keywords: ['mcp', 'enable', '有効', 'サーバー']),
  _row(SettingsSection.mcp, '書き込みの前に確認する', subtitle: 'push など外に作用する道具は、承認したときだけ実行します', keywords: ['mcp', 'approve', '承認', '確認', 'push', '書き込み']),
  _row(SettingsSection.mcp, '道具が多いときは、探して呼ぶ', subtitle: 'モデルに mcp_find（探す）・mcp_describe（定義を読む）・mcp_call（呼ぶ）の 3 つだけを渡します。', keywords: ['on demand', 'オンデマンド', 'mcp_find', 'mcp_call', 'mcp_describe', '事前プロンプト', 'トークン', '削減', 'ツール定義'], key: 'mcpOnDemand'),
  _row(SettingsSection.mcp, 'この大きさを超えたら', subtitle: 'MCP の道具の定義が合わせて約 2000 トークンを超えるとき、毎回の送信に定義を載せません。', keywords: ['on demand', 'オンデマンド', 'mcp_find', 'しきい値', 'トークン', '常に'], key: 'mcpOnDemandTokens'),
  _row(SettingsSection.mcp, '確認しない道具', subtitle: '承認カードで「この道具は次から確認しない」を選んだ道具です。外すと、また確認します。チャットからは変えられません（メッセージで確認を切られないため）。', keywords: ['approved', '許可', '記憶', '承認', '次から確認しない', 'mcp'], key: 'approvedTools'),

  // ------------------------------------------------------------------ model-wide settings
  _row(SettingsSection.basic, '思考の表示', subtitle: '生成中の状態と思考プロセスを表示します', keywords: ['thinking', '思考', '表示', 'reasoning'], key: 'thinking'),
  _row(SettingsSection.basic, '思考の内容を開いたまま表示', subtitle: 'オフにすると、思考が終わったあとは折りたたみます（見出しをタップで開け閉めできます）', keywords: ['thinking', '思考', '折りたたみ', '展開'], key: 'thinkingExpanded'),
  _row(SettingsSection.basic, '長いコードブロックを折りたたむ行数', subtitle: 'この行数より長いコードは、最初は折りたたみます（見出しをタップで開け閉めできます）。0 なら折りたたみません', keywords: ['code', 'コード', '折りたたみ', '行数', 'fold'], key: 'codeFoldLines'),
  _row(SettingsSection.basic, 'HTML・SVG をチャットの中で表示する高さ', subtitle: 'HTML と SVG のコードブロックに「表示」のボタンを出し、押すと、この高さでチャットの中に表示します。0 ならボタンを出しません', keywords: ['html', 'svg', 'preview', 'プレビュー', '表示', 'webview', 'ブラウザ', 'グラフィカル'], key: 'inlinePreviewHeight'),
  _row(SettingsSection.basic, 'モデルが画面にページを出せるようにする（show）', subtitle: 'HTML・SVG・/workspace のファイル・Linux 環境のプログラムが出すページを、モデルがチャットの中のカードとして出します。ボタンを押すと開きます', keywords: ['show', '画面', 'ページ', 'html', 'ビューア', 'グラフィカル', 'ポート', 'port'], key: 'showEnabled'),
  _row(SettingsSection.basic, 'ページを自動で開く', subtitle: 'ボタンを押さなくても、チャットの中のページを開きます。モデルが書いたページを、そのまま動かすので、オフのままをおすすめします（チャットからは変えられません）', keywords: ['auto', '自動', 'ページ', 'html', 'show', 'webview'], key: 'autoShowPages'),
  _row(SettingsSection.basic, 'タイトルをモデルに考えさせる', subtitle: 'オフにすると、最初の質問がそのままタイトルになります', keywords: ['title', 'タイトル', '履歴', '自動'], key: 'autoTitle'),
  _row(SettingsSection.basic, 'タイトルを考えるモデル', subtitle: '未選択なら、使用中のオンラインモデル（安いモデルにすると節約できます）', keywords: ['title', 'タイトル', 'モデル', '節約'], key: 'titleModel'),
  _row(SettingsSection.basic, 'タイトルの最大文字数', subtitle: '長いタイトルは、この長さで切ります', keywords: ['title', 'タイトル', '文字数'], key: 'titleMaxChars'),
  _row(SettingsSection.basic, '口調', subtitle: '回答の話し方（200文字まで）。ルールは変えられません', keywords: ['tone', '話し方', '丁寧', 'キャラ', 'スタイル'], key: 'tone'),
  _row(SettingsSection.basic, '速度 ⇔ 精度', subtitle: '左: 速い（思考を省略） / 右: 正確（長く考える）', keywords: ['speed', 'accuracy', '速度', '精度', 'スライダー', '思考の量'], key: 'speedAccuracy'),
  _row(SettingsSection.basic, 'エージェント', subtitle: '用途に合わせた役割。自動のときは内容から選びます', keywords: ['agent', '役割', 'coding', 'research', 'artifact', '自動'], key: 'agentOverride'),
  _row(SettingsSection.basic, 'AIによるエージェント選択', subtitle: '判断に迷うときだけ読み込み済みモデルに選ばせます', keywords: ['agent', 'エージェント', '自動', 'ai'], key: 'aiAgentSelection'),
  _row(SettingsSection.basic, '返信の最大文字数', subtitle: '0 は制限なし', keywords: ['length', '文字数', '返信', '長さ', '制限'], key: 'maxChars'),
  _row(SettingsSection.basic, '最大トークン数（共通）', subtitle: '1回の返信の長さの目安（思考の分も含みます）。ローカル・オンラインで別に決めたとき、また DeepSeek V4・GLM-5 のように公式の推奨があるモデルでは、そちらが先です', keywords: ['max tokens', 'max_tokens', '返信の長さ', 'トークン'], key: 'maxTokens'),
  _row(SettingsSection.basic, 'エラー再書き込み回数', subtitle: '途中で切れたツール呼び出しを書き直す回数', keywords: ['retry', '再試行', 'リトライ', 'ツール呼び出し', '書き直し'], key: 'retryLimit'),
  _row(SettingsSection.basic, 'ツール呼び出しの上限', subtitle: '1回の返信の中で使えるツールの回数の上限です。引数が違う呼び出し（別の言葉での検索など）は、繰り返しとはみなしません', keywords: ['tool', 'ツール', '道具', '回数', '上限', 'rounds'], key: 'maxToolRounds'),

  // ------------------------------------------------------------------ search
  _row(SettingsSection.search, 'SearXNG のアドレス', subtitle: '自分の検索サーバー（先に使います）', keywords: ['searxng', 'search', '検索サーバー', 'url', 'アドレス'], key: 'searxngUrl'),
  _row(SettingsSection.search, '検索結果の件数', subtitle: 'Web検索で使う結果の数', keywords: ['search', '検索', '件数', '結果', 'web'], key: 'searchResultCount'),
  _row(SettingsSection.search, '検索 API', keywords: ['search api', 'brave', 'tavily', 'exa', 'serper', 'api', '検索', 'キー', 'key']),
  _row(SettingsSection.search, '検索 API を追加', subtitle: 'JSON を返すサービスに対応します（GET と POST）。{query} が検索語、{count} が件数、{key} が API キーに入れ替わります', keywords: ['search api', 'brave', 'tavily', 'exa', 'serper', 'ひな形', 'テンプレート', 'キー']),
  _row(SettingsSection.search, 'この検索 API を使う', subtitle: 'オフの間は検索に使いません', keywords: ['search api', '有効', 'enable']),

  // ------------------------------------------------------------------ display, notifications, privacy
  _row(SettingsSection.display, '許可や答えが必要になったら通知する', subtitle: '承認カードや質問で返信が止まったとき（Android）', keywords: ['通知', 'notification', 'notify', '許可', '承認', '質問'], key: 'notifyNeedsYou'),
  _row(SettingsSection.display, '返信が終わったら通知する', subtitle: '長い作業を任せて、ほかのアプリを開いているとき', keywords: ['通知', 'notification', 'notify', '完了', '終わった'], key: 'notifyDone'),
  _row(SettingsSection.display, '失敗したら通知する', subtitle: 'エラーで返信が止まったとき', keywords: ['通知', 'notification', 'notify', 'エラー', '失敗'], key: 'notifyFailed'),
  _row(SettingsSection.display, 'そのチャットを開いているときは通知しない', subtitle: 'オフにすると、画面を見ているときも通知します', keywords: ['通知', 'notification', 'notify', '前面', '開いている'], key: 'notifyOnlyAway'),
  _row(SettingsSection.display, '文字の大きさ', subtitle: '画面全体の文字（端末の文字サイズの設定に重ねて効きます）', keywords: ['font', 'フォント', 'サイズ', '拡大', 'アクセシビリティ', 'scale'], key: 'fontScale'),
  _row(SettingsSection.display, 'テーマ', subtitle: '画面の明るさ', keywords: ['theme', 'ダーク', 'ライト', 'dark', 'light', '明るさ', '外観'], key: 'theme'),
  _row(SettingsSection.display, '思考中のアイコン', subtitle: '生成中に使う表示スタイル', keywords: ['thinking', 'アイコン', '思考', 'アニメーション', 'スタイル'], key: 'thinkingStyle'),
  _row(SettingsSection.display, '端末内保存', subtitle: '会話とモデルはこの端末内にだけ保存されます', keywords: ['privacy', 'プライバシー', '保存', 'ローカル', 'データ']),

  // ------------------------------------------------------------------ updates
  _row(SettingsSection.update, '更新を確認', subtitle: 'GitHub のリリースから新しい版を探します。', keywords: ['update', 'アップデート', 'バージョン', 'version', 'リリース', '確認']),
  _row(SettingsSection.update, '自動で確認する', subtitle: '起動時と、起動中は一定時間ごとに確認します', keywords: ['update', 'アップデート', '自動', '確認'], key: 'autoUpdateCheck'),
  _row(SettingsSection.update, '自動で更新する', subtitle: '見つけたらダウンロードとインストールまで自動で進めます', keywords: ['update', 'アップデート', '自動', 'インストール', 'ダウンロード'], key: 'autoInstallUpdate'),
  _row(SettingsSection.update, '差分だけダウンロードする', subtitle: 'Android：今のアプリとの差分があれば、それだけ取って新しいアプリを組み立てます（なければ全体）', keywords: ['delta', '差分', 'diff', 'bspatch', 'update', 'ダウンロード', '容量', '通信量'], key: 'updateUseDelta'),
  _row(SettingsSection.update, '確認の間隔', subtitle: '時間', keywords: ['update', 'アップデート', '間隔', '時間', 'interval'], key: 'updateIntervalHours'),
  _row(SettingsSection.update, 'リポジトリ', subtitle: '更新を探す GitHub のリポジトリ（owner/name）', keywords: ['repo', 'repository', 'github', 'owner', 'update'], key: 'updateRepo'),
  _row(SettingsSection.update, 'GitHub トークン', subtitle: '非公開リポジトリのときだけ。この端末の安全な領域に保存します', keywords: ['token', 'トークン', 'github', 'pat', '秘密', '非公開', 'private']),

  // ------------------------------------------------------------------ error reports
  _row(SettingsSection.reports, 'エラーを自動で送る', keywords: ['error', 'エラー', '報告', 'issue', 'report', '自動', 'クラッシュ'], key: 'errorReportEnabled'),
  _row(SettingsSection.reports, '送り先のリポジトリ', subtitle: 'owner/name。チャットからは変えられません', keywords: ['repo', 'repository', 'github', 'issue', 'owner'], key: 'errorReportRepo'),
  _row(SettingsSection.reports, 'issue 用の GitHub トークン', subtitle: 'そのリポジトリだけに、Issues の書き込み権限を付けた細かい権限のトークン（fine-grained）を作って入れてください。この端末の安全な領域に保存します。アップデート用のトークンとは別です', keywords: ['token', 'トークン', 'github', 'pat', 'fine-grained', '秘密', 'issues']),
  _row(SettingsSection.reports, '同じ問題にコメントする間隔', subtitle: 'この間は、同じ問題は数えるだけで送りません', keywords: ['error', 'エラー', '間隔', 'コメント', '時間'], key: 'errorReportMinHours'),
  _row(SettingsSection.reports, '1 時間に送る件数の上限', subtitle: 'すべての報告の合計。多すぎるときは送りません', keywords: ['error', 'エラー', '件数', '上限', 'rate limit'], key: 'errorReportMaxPerHour'),
  _row(SettingsSection.reports, 'テスト送信', keywords: ['error', 'エラー', 'テスト', 'issue', '送信']),

  // ---- agent C (prompt cache)
  _row(SettingsSection.providers, 'プロンプトのキャッシュ用の印を送る', subtitle: 'オンにすると、同じ会話のリクエストに、同じ印（下の項目名）を付けて送ります。', keywords: ['cache', 'キャッシュ', 'prompt_cache_key', 'prompt cache', 'プロンプトキャッシュ', 'openai', 'deepseek', 'gemini', 'api', '印', 'キー']),
  _row(SettingsSection.providers, 'キャッシュの項目名', keywords: ['cache', 'キャッシュ', 'prompt_cache_key', '項目', 'フィールド', 'field']),

  // ---- agent B (model availability)
  _row(SettingsSection.providers, '使えないと分かったモデルを、選択肢から隠す', subtitle: 'オフ（既定）では、灰色にして最後に並べます。使っているモデルは、隠れません', keywords: ['gemini', '無料枠', 'free tier', 'quota', '使えない', 'モデル', '隠す', 'hide', '選択肢', 'blocked'], key: 'hideUnusableModels'),
  _row(SettingsSection.providers, '送信で使えないと分かったら、印を付ける', subtitle: '「このキー（プラン）では使えない」という答えが返ったモデルに、印を付けます', keywords: ['gemini', '無料枠', 'free tier', '429', '403', '404', '使えない', '印', 'マーク', 'blocked'], key: 'markBlockedModels'),
  _row(SettingsSection.providers, '印を信じる日数', subtitle: 'この日数が過ぎた印は外します', keywords: ['使えない', '印', '期限', '日数', 'プラン', 'expire'], key: 'modelAvailabilityTrustDays'),
  _row(SettingsSection.providers, '確かめるときの同時の数', subtitle: '「設定中のモデルを確かめる」が、同時に問い合わせるモデルの数', keywords: ['設定中のモデルを確かめる', 'probe', '同時', '並列', 'concurrency'], key: 'modelProbeConcurrency'),
  _row(SettingsSection.providers, '確かめるときの待ち時間', subtitle: '1 つのモデルの返事を待つ時間。過ぎたら一時的な失敗として扱い、印は付けません', keywords: ['設定中のモデルを確かめる', 'probe', 'タイムアウト', 'timeout', '待ち時間'], key: 'modelProbeTimeoutSeconds'),
  _row(SettingsSection.providers, '印をすべて消す', subtitle: '覚えている「使える・使えない」を、すべて忘れます', keywords: ['使えない', '印', '消す', 'リセット', 'clear']),
  _row(SettingsSection.providers, '設定中のモデルを確かめる', subtitle: 'モデルの一覧のボタン。答えるモデル・分担モードのモデル・タイトル用のモデルだけを、そのキーで読めるモデル一覧で調べます（一覧にないモデルや、チャットに対応していないモデルに印が付きます）', keywords: ['gemini', '無料枠', 'free tier', 'probe', '確認', '使えない', 'モデル', 'キー', 'プラン', '429', '403', '設定中', '確かめる']),
  _row(SettingsSection.providers, '一覧にあるモデルにも、短い問い合わせを 1 回送る', subtitle: 'オフ（既定）では、モデル一覧だけで判断します（回数を使いません）。オンにすると、無料枠で使えないモデルまで分かります（確かめるたびに、回数を 1 回ずつ使います）', keywords: ['gemini', '無料枠', 'free tier', '問い合わせ', '回数', 'models.list', 'probe', '確認', '使えない'], key: 'modelCheckAsksToo'),
  _row(SettingsSection.providers, 'モデルを選んだとき、そのモデルを 1 回だけ確かめる', subtitle: '答えるモデルを変えたとき、そのモデル 1 つを確かめます（モデル一覧で判断します。印が新しければ確かめません）。使えないときは、そう知らせます', keywords: ['gemini', '無料枠', 'free tier', '自動', '確認', '使えない', 'モデル', '選ぶ', 'auto', 'probe'], key: 'autoCheckSelectedModel'),

  // ---- agent C (secrets screen)
  _row(SettingsSection.shell, 'モデルに使わせる', subtitle: '', keywords: ['secret', '秘密', 'モデル', 'スイッチ', 'オフ', '使わせない', 'placeholder', 'プレースホルダー', 'secret:id'], key: 'secretsOffForModel'),
  _row(SettingsSection.shell, '環境変数の名前', keywords: ['secret', '秘密', '環境変数', 'env', '名前', 'github_token', 'gh_token']),
  _row(SettingsSection.shell, '送ってよいホスト（1 行に 1 つ）', keywords: ['secret', '秘密', 'ホスト', 'host', 'ドメイン', 'domain', '送り先', '*', 'ワイルドカード', 'api.github.com', 'placeholder', 'プレースホルダー']),
  _row(SettingsSection.shell, 'API を呼ぶ道具（http_request）', subtitle: 'API を呼ぶだけなら、`http_request` を使わせます。', keywords: ['http_request', 'http', 'api', 'curl', 'リクエスト', 'request', '秘密', 'secret', 'プレースホルダー', 'placeholder', 'キー', 'トークン']),
  _row(SettingsSection.shell, 'モデルが http_request（アプリが API を呼ぶ道具）を使えるようにする', subtitle: 'オフにすると、モデルにこの道具を渡しません', keywords: ['http_request', 'http', 'api', 'curl', 'オフ', 'スイッチ', '道具', 'tool'], key: 'httpRequestEnabled'),
  _row(SettingsSection.shell, '呼び出しの前に確認する', keywords: ['http_request', '確認', '承認', 'confirm', 'approval', '毎回', '書き込み', '秘密', 'secret'], key: 'httpRequestConfirm'),
  _row(SettingsSection.shell, 'http（暗号化されない通信）でも、キーやトークンを送れるようにする', subtitle: '既定はオフ（https だけ）。オンにすると、通信の途中で、キーを見られるおそれがあります。', keywords: ['http_request', 'http', 'https', '暗号化', 'insecure', '秘密', 'secret', 'キー', 'トークン', '危険'], key: 'httpRequestAllowInsecure'),
  _row(SettingsSection.shell, '応答を、モデルに渡す文字数の上限', subtitle: '超えた分は省きます', keywords: ['http_request', '応答', 'レスポンス', 'response', '文字数', '上限', 'max', '省く'], key: 'httpRequestMaxResponseChars'),
  _row(SettingsSection.shell, 'http_request が追うリダイレクトの回数', subtitle: '秘密を使うときは、同じホストの https にだけ追います。0 は追いません', keywords: ['http_request', 'リダイレクト', 'redirect', '転送', '回数'], key: 'httpRequestMaxRedirects'),
  _row(SettingsSection.shell, 'http_request の待ち時間', subtitle: 'この秒数で、通信をあきらめます', keywords: ['http_request', 'タイムアウト', 'timeout', '待ち時間', '秒'], key: 'httpRequestTimeoutSeconds'),
];
