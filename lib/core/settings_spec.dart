/// The settings the agent may change, with the range the app accepts for each one.
///
/// Only what is listed in [specs] can be changed. Two kinds of setting stay out of reach:
///
/// * API keys and the GitHub token. They are not part of `AppSettings` at all (they live in the
///   platform's secure storage), and the model must never read or write them.
/// * `lastModelPath` and `updateRepo`. The first is app state, not a preference; the second
///   decides where an update comes from, so pointing it somewhere else is a supply-chain
///   change that a chat message must not be able to make.
///
/// A change produced here is only a proposal: the chat shows it, and the app applies it only
/// after the user approves.
abstract final class AgentSettings {
  static const specs = <String, SettingSpec>{
    'thinking': SettingSpec(key: 'thinking', label: '思考プロセス', kind: SettingKind.flag),
    'searchEnabled': SettingSpec(key: 'searchEnabled', label: '検索', kind: SettingKind.flag),
    'searxngUrl': SettingSpec(
      key: 'searxngUrl',
      label: '検索サーバー',
      kind: SettingKind.url,
      maxLength: 300,
    ),
    'tone': SettingSpec(key: 'tone', label: '口調', kind: SettingKind.text, maxLength: 200),
    'maxChars': SettingSpec(key: 'maxChars', label: '回答の最大文字数', kind: SettingKind.whole, min: 0, max: 4000),
    'speedAccuracy': SettingSpec(
      key: 'speedAccuracy',
      label: '速度⇔精度',
      kind: SettingKind.decimal,
      min: 0,
      max: 1,
    ),
    'hyperLoad': SettingSpec(key: 'hyperLoad', label: 'ハイパーロード', kind: SettingKind.flag),
    'theme': SettingSpec(
      key: 'theme',
      label: 'テーマ',
      kind: SettingKind.choice,
      choices: ['system', 'light', 'dark'],
      choiceLabels: {'system': '端末に合わせる', 'light': 'ライト', 'dark': 'ダーク'},
    ),
    'thinkingStyle': SettingSpec(
      key: 'thinkingStyle',
      label: '思考中のアイコン',
      kind: SettingKind.choice,
      choices: ['basic', 'ring', 'pulse', 'dots', 'rotation'],
      choiceLabels: {
        'basic': '基本',
        'ring': 'リング',
        'pulse': 'パルス',
        'dots': 'ドット',
        'rotation': 'ローテーション',
      },
    ),
    'agentOverride': SettingSpec(
      key: 'agentOverride',
      label: 'エージェント',
      kind: SettingKind.text,
      maxLength: 40,
    ),
    'aiAgentSelection': SettingSpec(
      key: 'aiAgentSelection',
      label: 'エージェントの自動選択',
      kind: SettingKind.flag,
    ),
    'contextLength': SettingSpec(
      key: 'contextLength',
      label: 'コンテキスト長',
      kind: SettingKind.whole,
      min: 512,
      max: 131072,
    ),
    'threads': SettingSpec(key: 'threads', label: 'スレッド数', kind: SettingKind.whole, min: 0, max: 64),
    'batchSize': SettingSpec(key: 'batchSize', label: 'バッチサイズ', kind: SettingKind.whole, min: 0, max: 1024),
    'gpuOffload': SettingSpec(
      key: 'gpuOffload',
      label: 'GPU',
      kind: SettingKind.choice,
      choices: ['auto', 'cpuOnly', 'gpuPriority', 'maxGpu'],
      choiceLabels: {
        'auto': '自動',
        'cpuOnly': 'CPUのみ',
        'gpuPriority': 'GPU優先',
        'maxGpu': '最大GPU',
      },
    ),
    'maxTokens': SettingSpec(
      key: 'maxTokens',
      label: '最大トークン',
      kind: SettingKind.whole,
      min: 256,
      max: 1048576,
    ),
    'retryLimit': SettingSpec(
      key: 'retryLimit',
      label: 'エラー再書き込み回数',
      kind: SettingKind.whole,
      min: 0,
      max: 10,
    ),
    'maxToolRounds': SettingSpec(
      key: 'maxToolRounds',
      label: 'ツール呼び出しの上限（1回の返信の中。0で上限なし）',
      kind: SettingKind.whole,
      min: 0,
      max: 200,
    ),
    'forceExecution': SettingSpec(key: 'forceExecution', label: '強制実行', kind: SettingKind.flag),
    'autoUpdateCheck': SettingSpec(
      key: 'autoUpdateCheck',
      label: '更新の自動確認',
      kind: SettingKind.flag,
    ),
    'updateIntervalHours': SettingSpec(
      key: 'updateIntervalHours',
      label: '更新確認の間隔（時間）',
      kind: SettingKind.whole,
      min: 1,
      max: 168,
    ),
    'autoInstallUpdate': SettingSpec(
      key: 'autoInstallUpdate',
      label: '更新の自動インストール',
      kind: SettingKind.flag,
    ),
    // The device model and the online models have their own set; -1 (0 for a token count, empty
    // for a prompt) means "not set", and the app's own value applies.
    'localTemperature': SettingSpec(
      key: 'localTemperature',
      label: 'ローカル: temperature（-1で既定）',
      kind: SettingKind.decimal,
      min: -1,
      max: 2,
    ),
    'localTopP': SettingSpec(
      key: 'localTopP',
      label: 'ローカル: top_p（-1で既定）',
      kind: SettingKind.decimal,
      min: -1,
      max: 1,
    ),
    'localTopK': SettingSpec(
      key: 'localTopK',
      label: 'ローカル: top_k（0で既定）',
      kind: SettingKind.whole,
      min: 0,
      max: 200,
    ),
    'localMinP': SettingSpec(
      key: 'localMinP',
      label: 'ローカル: min_p（-1で既定）',
      kind: SettingKind.decimal,
      min: -1,
      max: 1,
    ),
    'localMaxTokens': SettingSpec(
      key: 'localMaxTokens',
      label: 'ローカル: 最大トークン（0で共通の値）',
      kind: SettingKind.whole,
      min: 0,
      max: 32768,
    ),
    'localPrompt': SettingSpec(
      key: 'localPrompt',
      label: 'ローカル: 追加プロンプト',
      kind: SettingKind.text,
      maxLength: 2000,
    ),
    'onlineTemperature': SettingSpec(
      key: 'onlineTemperature',
      label: 'オンライン: temperature（-1で既定）',
      kind: SettingKind.decimal,
      min: -1,
      max: 2,
    ),
    'onlineTopP': SettingSpec(
      key: 'onlineTopP',
      label: 'オンライン: top_p（-1で既定）',
      kind: SettingKind.decimal,
      min: -1,
      max: 1,
    ),
    'onlineMaxTokens': SettingSpec(
      key: 'onlineMaxTokens',
      label: 'オンライン: 最大トークン（0でモデルの推奨か共通の値）',
      kind: SettingKind.whole,
      min: 0,
      max: 1048576,
    ),
    'onlineUseModelMax': SettingSpec(
      key: 'onlineUseModelMax',
      label: 'オンライン: 最大トークンが 0 のとき、モデルごとの最大出力にする',
      kind: SettingKind.flag,
    ),
    'onlinePrompt': SettingSpec(
      key: 'onlinePrompt',
      label: 'オンライン: 追加プロンプト',
      kind: SettingKind.text,
      maxLength: 2000,
    ),
    // Coding mode: the planner model answers and hands jobs to the developer model. A model is
    // written `providerId|modelId` (`local|` is the model on the device).
    'codingPlanEnabled': SettingSpec(
      key: 'codingPlanEnabled',
      label: '分担モード（plan＋coding の分担）',
      kind: SettingKind.flag,
    ),
    'mcpOnDemand': SettingSpec(key: 'mcpOnDemand', label: 'MCP の道具が多いとき、定義を送らず、必要なときに探して呼ぶ', kind: SettingKind.flag),
    'mcpOnDemandTokens': SettingSpec(key: 'mcpOnDemandTokens', label: 'MCP の道具の定義がこの大きさ（トークン）を超えたら、探して呼ぶ方式にする（0 で常に）', kind: SettingKind.whole, min: 0, max: 100000),
    'compactEnabled': SettingSpec(key: 'compactEnabled', label: '長い会話を要約して、文脈に収める', kind: SettingKind.flag),
    'compactAtPercent': SettingSpec(key: 'compactAtPercent', label: '要約を始める、文脈の使用率（%）', kind: SettingKind.whole, min: 30, max: 95),
    'compactKeepTurns': SettingSpec(key: 'compactKeepTurns', label: '要約せずに残す、直近の発言の数', kind: SettingKind.whole, min: 1, max: 30),
    'compactSummaryChars': SettingSpec(key: 'compactSummaryChars', label: '要約の長さ（文字）', kind: SettingKind.whole, min: 300, max: 20000),
    'compactToolResultChars': SettingSpec(key: 'compactToolResultChars', label: '古い道具の結果を切り詰める長さ（文字）', kind: SettingKind.whole, min: 200, max: 50000),
    'notifyNeedsYou': SettingSpec(key: 'notifyNeedsYou', label: '通知: 許可や答えが必要になったとき', kind: SettingKind.flag),
    'notifyDone': SettingSpec(key: 'notifyDone', label: '通知: 返信が終わったとき', kind: SettingKind.flag),
    'notifyFailed': SettingSpec(key: 'notifyFailed', label: '通知: 失敗したとき', kind: SettingKind.flag),
    'notifyOnlyAway': SettingSpec(key: 'notifyOnlyAway', label: '通知: そのチャットを開いていないときだけ出す', kind: SettingKind.flag),
    'codingPlannerFollows': SettingSpec(
      key: 'codingPlannerFollows',
      label: '分担モード: plan は、使用中のモデルに合わせる（オフなら下の plan のモデル）',
      kind: SettingKind.flag,
    ),
    'developerModelsMore': SettingSpec(
      key: 'developerModelsMore',
      label: '分担モード: coding の追加モデル（provider|model を 1 行に 1 つ）',
      kind: SettingKind.text,
      maxLength: 1000,
    ),
    'plannerModel': SettingSpec(key: 'plannerModel', label: 'plan のモデル（provider|model）', kind: SettingKind.text, maxLength: 120),
    'developerModel': SettingSpec(key: 'developerModel', label: 'coding のモデル（provider|model）', kind: SettingKind.text, maxLength: 120),
    'codingMaxTasks': SettingSpec(
      key: 'codingMaxTasks',
      label: '分担モード: 1 回の依頼に入れるタスクの最大数',
      kind: SettingKind.whole,
      min: 1,
      max: 16,
    ),
    'codingParallel': SettingSpec(
      key: 'codingParallel',
      label: '分担モード: 1 つの coding が同時に走らせる数',
      kind: SettingKind.whole,
      min: 1,
      max: 8,
    ),
    'codingInvestigateFirst': SettingSpec(
      key: 'codingInvestigateFirst',
      label: '分担モード: 先に担当を調べてレポートを集め、あなたの確認のあとで実装する',
      kind: SettingKind.flag,
    ),
    'codingMaxWorkers': SettingSpec(
      key: 'codingMaxWorkers',
      label: '分担モード: 分担数の上限（同時に動く担当の数）',
      kind: SettingKind.whole,
      min: 1,
      max: 16,
    ),
    'codingReviewRounds': SettingSpec(
      key: 'codingReviewRounds',
      label: '分担モード: plan が書き直しを指示できる回数',
      kind: SettingKind.whole,
      min: 0,
      max: 3,
    ),
    'codingResultChars': SettingSpec(
      key: 'codingResultChars',
      label: '分担モード: plan が読む、coding の結果の文字数（1 件ごと）',
      kind: SettingKind.whole,
      min: 500,
      max: 1000000,
    ),
    'codingDeveloperMaxTokens': SettingSpec(
      key: 'codingDeveloperMaxTokens',
      label: '分担モード: coding の最大トークン（0で自動）',
      kind: SettingKind.whole,
      min: 0,
      max: 1048576,
    ),
    // limits and timeouts
    'previewMaxPages': SettingSpec(
      key: 'previewMaxPages',
      label: 'ブラウザで開く試作ページを残す数',
      kind: SettingKind.whole,
      min: 1,
      max: 500,
    ),
    'attachMaxFiles': SettingSpec(
      key: 'attachMaxFiles',
      label: '添付できるファイルの数',
      kind: SettingKind.whole,
      min: 1,
      max: 20,
    ),
    'attachCharsPerFile': SettingSpec(
      key: 'attachCharsPerFile',
      label: '添付1ファイルから読む文字数',
      kind: SettingKind.whole,
      min: 500,
      max: 200000,
    ),
    'attachTotalChars': SettingSpec(
      key: 'attachTotalChars',
      label: '添付全体で読む文字数',
      kind: SettingKind.whole,
      min: 1000,
      max: 400000,
    ),
    'attachImageMb': SettingSpec(
      key: 'attachImageMb',
      label: '送る画像の大きさの上限（MB）',
      kind: SettingKind.whole,
      min: 1,
      max: 20,
    ),
    'searchResultCount': SettingSpec(
      key: 'searchResultCount',
      label: '検索結果の件数',
      kind: SettingKind.whole,
      min: 1,
      max: 20,
    ),
    'httpTimeoutSeconds': SettingSpec(
      key: 'httpTimeoutSeconds',
      label: '検索・天気の通信のタイムアウト（秒）',
      kind: SettingKind.whole,
      min: 3,
      max: 300,
    ),
    'mcpTimeoutSeconds': SettingSpec(
      key: 'mcpTimeoutSeconds',
      label: 'MCPサーバーのタイムアウト（秒）',
      kind: SettingKind.whole,
      min: 5,
      max: 600,
    ),
    'mcpResultMaxChars': SettingSpec(
      key: 'mcpResultMaxChars',
      label: 'MCP の道具の結果を、モデルに渡す文字数の上限',
      kind: SettingKind.whole,
      min: 500,
      max: 1000000,
    ),
    'providerTimeoutSeconds': SettingSpec(
      key: 'providerTimeoutSeconds',
      label: 'オンラインモデルの応答のタイムアウト（秒）',
      kind: SettingKind.whole,
      min: 10,
      max: 1800,
    ),
    'toolRepeatLimit': SettingSpec(
      key: 'toolRepeatLimit',
      label: '同じツール呼び出しの繰り返しで止める回数',
      kind: SettingKind.whole,
      min: 2,
      max: 10,
    ),
    'updateRetryAttempts': SettingSpec(
      key: 'updateRetryAttempts',
      label: 'ダウンロードの試行回数',
      kind: SettingKind.whole,
      min: 1,
      max: 20,
    ),
    'updateStallSeconds': SettingSpec(
      key: 'updateStallSeconds',
      label: 'ダウンロードの無通信の判定（秒）',
      kind: SettingKind.whole,
      min: 5,
      max: 600,
    ),
    'updateUseDelta': SettingSpec(
      key: 'updateUseDelta',
      label: '更新は差分だけダウンロード（Android）',
      kind: SettingKind.flag,
    ),
    'fontScale': SettingSpec(
      key: 'fontScale',
      label: '文字の大きさ（1 が標準）',
      kind: SettingKind.decimal,
      min: 0.7,
      max: 2.0,
    ),
    'modelListAutoFetch': SettingSpec(
      key: 'modelListAutoFetch',
      label: 'プロバイダのモデル一覧を自動で取得する',
      kind: SettingKind.flag,
    ),
    'modelListRefreshHours': SettingSpec(
      key: 'modelListRefreshHours',
      label: 'モデル一覧を取り直す間隔（時間）',
      kind: SettingKind.whole,
      min: 1,
      max: 720,
    ),
    'fallbackEnabled': SettingSpec(
      key: 'fallbackEnabled',
      label: 'モデルが使えないとき、決めておいた別のモデルに切り替える',
      kind: SettingKind.flag,
    ),
    'tokenPrecheck': SettingSpec(
      key: 'tokenPrecheck',
      label: '送る前にトークン長を見積もり、収まらないときは先にエラーにする',
      kind: SettingKind.flag,
    ),
    'thinkingExpanded': SettingSpec(
      key: 'thinkingExpanded',
      label: '思考の内容を、開いたまま表示する',
      kind: SettingKind.flag,
    ),
    'codeFoldLines': SettingSpec(
      key: 'codeFoldLines',
      label: 'この行数より長いコードブロックを、最初は折りたたむ（0で折りたたまない）',
      kind: SettingKind.whole,
      min: 0,
      max: 1000,
    ),
    'inlinePreviewHeight': SettingSpec(
      key: 'inlinePreviewHeight',
      label: 'HTML・SVG のコードブロックを、チャットの中で表示するときの高さ（0で表示のボタンを出さない）',
      kind: SettingKind.whole,
      min: 0,
      max: 2000,
    ),
    'showEnabled': SettingSpec(
      key: 'showEnabled',
      label: 'モデルが道具 show で、ページをチャットに出せるようにする',
      kind: SettingKind.flag,
    ),
    'showMaxChars': SettingSpec(
      key: 'showMaxChars',
      label: 'show で一度に渡せるページ（HTML・SVG）の最大文字数',
      kind: SettingKind.whole,
      min: 1000,
      max: 2000000,
    ),
    'showMaxFileMb': SettingSpec(
      key: 'showMaxFileMb',
      label: 'show で表示するフォルダから配るファイルの最大サイズ（MB）',
      kind: SettingKind.whole,
      min: 1,
      max: 500,
    ),
    'errorReportMinHours': SettingSpec(
      key: 'errorReportMinHours',
      label: 'エラー報告：同じ問題にコメントする間隔（時間）',
      kind: SettingKind.whole,
      min: 1,
      max: 168,
    ),
    'errorReportMaxPerHour': SettingSpec(
      key: 'errorReportMaxPerHour',
      label: 'エラー報告：1 時間に送る件数の上限',
      kind: SettingKind.whole,
      min: 1,
      max: 60,
    ),
    'autoTitle': SettingSpec(
      key: 'autoTitle',
      label: '新しい会話のタイトルを、モデルに考えさせる',
      kind: SettingKind.flag,
    ),
    'titleModel': SettingSpec(
      key: 'titleModel',
      label: 'タイトルを考えるモデル（provider|model。空なら使用中のオンラインモデル）',
      kind: SettingKind.text,
      maxLength: 120,
    ),
    'titleMaxChars': SettingSpec(
      key: 'titleMaxChars',
      label: 'タイトルの最大文字数',
      kind: SettingKind.whole,
      min: 8,
      max: 80,
    ),
    'tokenOverheadPercent': SettingSpec(
      key: 'tokenOverheadPercent',
      label: '指示とツール定義が使ってよい文脈の割合（%）',
      kind: SettingKind.whole,
      min: 10,
      max: 100,
    ),
    'recentModelCount': SettingSpec(
      key: 'recentModelCount',
      label: '最近使ったモデルを、一覧の先頭に出す数（0でなし）',
      kind: SettingKind.whole,
      min: 0,
      max: 30,
    ),
    'hideUnusableModels': SettingSpec(
      key: 'hideUnusableModels',
      label: '使えないと分かったモデルを、選択肢から隠す（オフなら、灰色にして最後に並べる）',
      kind: SettingKind.flag,
    ),
    'httpRequestEnabled': SettingSpec(key: 'httpRequestEnabled', label: 'モデルが http_request（アプリが API を呼ぶ道具）を使えるようにする', kind: SettingKind.flag),
    'httpRequestMaxResponseChars': SettingSpec(key: 'httpRequestMaxResponseChars', label: 'http_request の応答を、モデルに渡す文字数の上限', kind: SettingKind.whole, min: 500, max: 1000000),
    'httpRequestMaxRedirects': SettingSpec(key: 'httpRequestMaxRedirects', label: 'http_request が追うリダイレクトの回数の上限（0 で追わない）', kind: SettingKind.whole, min: 0, max: 10),
    'httpRequestTimeoutSeconds': SettingSpec(key: 'httpRequestTimeoutSeconds', label: 'http_request の待ち時間（秒）', kind: SettingKind.whole, min: 3, max: 600),
    'modelCheckAsksToo': SettingSpec(key: 'modelCheckAsksToo', label: 'モデルの確認で、一覧にあるモデルにも短い問い合わせを 1 回送る（無料枠の使える・使えないまで分かる。回数を使う）', kind: SettingKind.flag),
    'autoCheckSelectedModel': SettingSpec(key: 'autoCheckSelectedModel', label: 'モデルを選んだとき、そのモデルがこのキーで使えるかを 1 回だけ確かめる', kind: SettingKind.flag),
    'markBlockedModels': SettingSpec(
      key: 'markBlockedModels',
      label: '送信が「このキーでは使えない」で失敗したとき、そのモデルに印を付ける',
      kind: SettingKind.flag,
    ),
    'modelProbeConcurrency': SettingSpec(
      key: 'modelProbeConcurrency',
      label: 'モデルの確認で、同時に問い合わせる数',
      kind: SettingKind.whole,
      min: 1,
      max: 8,
    ),
    'modelProbeTimeoutSeconds': SettingSpec(
      key: 'modelProbeTimeoutSeconds',
      label: 'モデルの確認で、1 モデルの返事を待つ時間（秒）',
      kind: SettingKind.whole,
      min: 5,
      max: 120,
    ),
    'modelAvailabilityTrustDays': SettingSpec(
      key: 'modelAvailabilityTrustDays',
      label: 'モデルの「使える・使えない」の印を信じる日数（プランは変わるので、過ぎたら印を外す）',
      kind: SettingKind.whole,
      min: 1,
      max: 90,
    ),
    'resumeDownloadsOnStart': SettingSpec(
      key: 'resumeDownloadsOnStart',
      label: '閉じたときに止まったモデルのダウンロードを、次の起動で続ける',
      kind: SettingKind.flag,
    ),
    'downloadConnections': SettingSpec(
      key: 'downloadConnections',
      label: 'ダウンロードの同時接続数（1で分けない）',
      kind: SettingKind.whole,
      min: 1,
      max: 16,
    ),
    'localDryMultiplier': SettingSpec(
      key: 'localDryMultiplier',
      label: 'ローカル: 繰り返しの抑制 DRY（-1で既定）',
      kind: SettingKind.decimal,
      min: -1,
      max: 5,
    ),
    // Finding out what an online model can do
    'autoFetchModelInfo': SettingSpec(
      key: 'autoFetchModelInfo',
      label: 'オンライン: モデルの上限を自動で調べる',
      kind: SettingKind.flag,
    ),
    'fetchModelInfoFromHub': SettingSpec(
      key: 'fetchModelInfoFromHub',
      label: 'オンライン: Hugging Face からも調べる',
      kind: SettingKind.flag,
    ),
    // Saving the device model's KV cache to files
    'kvSnapshotEnabled': SettingSpec(
      key: 'kvSnapshotEnabled',
      label: 'ローカル: 会話のKVキャッシュをファイルに保存',
      kind: SettingKind.flag,
    ),
    'kvSnapshotMaxMb': SettingSpec(
      key: 'kvSnapshotMaxMb',
      label: 'ローカル: 保存するKVキャッシュの合計の上限（MB）',
      kind: SettingKind.whole,
      min: 64,
      max: 65536,
    ),
    'kvSnapshotMinTokens': SettingSpec(
      key: 'kvSnapshotMinTokens',
      label: 'ローカル: KVキャッシュを保存する最小のトークン数',
      kind: SettingKind.whole,
      min: 64,
      max: 100000,
    ),
    // The Linux environment on the device. Two of them are missing on purpose:
    // `shellConfirm` decides whether a command is shown before it runs, and `linuxRootfsUrl` /
    // `linuxRootfsSha256` decide which system is downloaded: a chat message must not be able to
    // turn the first off or point the second somewhere else.
    'shellEnabled': SettingSpec(
      key: 'shellEnabled',
      label: 'Linux 環境のコマンド実行を使う',
      kind: SettingKind.flag,
    ),
    'shellTimeoutSeconds': SettingSpec(
      key: 'shellTimeoutSeconds',
      label: 'Linux 環境: コマンドのタイムアウト（秒）',
      kind: SettingKind.whole,
      min: 1,
      max: 3600,
    ),
    'shellMaxTimeoutSeconds': SettingSpec(
      key: 'shellMaxTimeoutSeconds',
      label: 'Linux 環境: モデルが指定できるタイムアウトの上限（秒）',
      kind: SettingKind.whole,
      min: 1,
      max: 3600,
    ),
    'shellMaxOutputChars': SettingSpec(
      key: 'shellMaxOutputChars',
      label: 'Linux 環境: コマンドの出力をモデルに渡す文字数の上限',
      kind: SettingKind.whole,
      min: 500,
      max: 1000000,
    ),
    'shellSessionMax': SettingSpec(key: 'shellSessionMax', label: 'Linux 環境: 同時に動かせる対話セッションの数', kind: SettingKind.whole, min: 1, max: 20),
    'shellSessionIdleMinutes': SettingSpec(key: 'shellSessionIdleMinutes', label: 'Linux 環境: 使われない対話セッションを止めるまでの時間（分。0で止めない）', kind: SettingKind.whole, min: 0, max: 1440),
    'shellSessionWaitMs': SettingSpec(key: 'shellSessionWaitMs', label: 'Linux 環境: 対話セッションの出力を待つ時間（ミリ秒）', kind: SettingKind.whole, min: 0, max: 120000),
    'shellSessionMaxWaitSeconds': SettingSpec(key: 'shellSessionMaxWaitSeconds', label: 'Linux 環境: モデルが指定できる、出力を待つ時間の上限（秒）', kind: SettingKind.whole, min: 1, max: 120),
    'shellSessionCols': SettingSpec(key: 'shellSessionCols', label: 'Linux 環境: 対話セッションの端末の幅（桁）', kind: SettingKind.whole, min: 20, max: 400),
    'shellSessionRows': SettingSpec(key: 'shellSessionRows', label: 'Linux 環境: 対話セッションの端末の高さ（行）', kind: SettingKind.whole, min: 5, max: 200),
    'shellSessionScrollback': SettingSpec(key: 'shellSessionScrollback', label: 'Linux 環境: 画面から流れた行を残す数', kind: SettingKind.whole, min: 0, max: 5000),
    'shellSessionBufferKb': SettingSpec(key: 'shellSessionBufferKb', label: 'Linux 環境: 読まれるまでに残す出力の大きさ（KB）', kind: SettingKind.whole, min: 16, max: 8192),
    'workspaceLimitMb': SettingSpec(
      key: 'workspaceLimitMb',
      label: 'Linux 環境: 全チャット共通のワークスペースの上限（MB。0で上限なし）',
      kind: SettingKind.whole,
      min: 0,
      max: 65536,
    ),
    'shellCompatMode': SettingSpec(
      key: 'shellCompatMode',
      label: 'Linux 環境: 互換モード（seccomp を切る）',
      kind: SettingKind.flag,
    ),
  };

  /// Sorted, so the grammar and the prompt show the same order every time.
  static List<String> get keys => specs.keys.toList()..sort();

  /// The names of the settings that are deliberately not reachable from a chat message.
  static const blocked = <String>{
    'lastModelPath',
    'updateRepo',
    'kvCache',
    'errorReportEnabled',
    'errorReportRepo',
    'shellConfirm',
    // a message must not switch off a question the app asks before a command or a tool runs
    'shellConfirmAfterExternal',
    'approvedTools',
    // which secrets a command may ask for: a message must not hand a token to a command
    'shellSecrets',
    // which secrets a model may use by placeholder: a message must not open a key to a model
    'secretsOffForModel',
    // a message must not switch off the question before a call that carries a secret, nor allow an unencrypted one
    'httpRequestConfirm',
    'httpRequestAllowInsecure',
    // a page that opens by itself runs what a model wrote without a press of the button: not for a message to switch on
    'autoShowPages',
    'linuxRootfsUrl',
    'linuxRootfsSha256',
    // where the names of the Linux environment are looked up: a chosen resolver can answer for any site
    'linuxDns',
  };

  static bool isEditable(String key) => specs.containsKey(key);

  /// Checks one value against its setting and converts it to what the app stores.
  static SettingsChangeResult normalize(String key, Object? raw) {
    final spec = specs[key];
    if (spec == null) {
      if (blocked.contains(key)) return SettingsChangeInvalid(key, '$key はチャットからは変更できません');
      return SettingsChangeInvalid(key, '$key という設定はありません');
    }

    switch (spec.kind) {
      case SettingKind.flag:
        final value = _flag(raw);
        if (value == null) return SettingsChangeInvalid(key, '${spec.label}は true か false で指定してください');
        return SettingsChangeOk(spec, value);

      case SettingKind.whole:
        final value = _number(raw);
        if (value == null || value != value.roundToDouble()) {
          return SettingsChangeInvalid(key, '${spec.label}は整数で指定してください');
        }
        final whole = value.toInt();
        return _range(spec, whole) ?? SettingsChangeOk(spec, whole);

      case SettingKind.decimal:
        final value = _number(raw);
        if (value == null) return SettingsChangeInvalid(key, '${spec.label}は数値で指定してください');
        return _range(spec, value) ?? SettingsChangeOk(spec, value);

      case SettingKind.choice:
        final text = raw?.toString().trim();
        if (text == null || !spec.choices.contains(text)) {
          return SettingsChangeInvalid(
            key,
            '${spec.label}は ${spec.choices.join(' / ')} のどれかで指定してください',
          );
        }
        return SettingsChangeOk(spec, text);

      case SettingKind.text:
      case SettingKind.url:
        if (raw is! String) return SettingsChangeInvalid(key, '${spec.label}は文字列で指定してください');
        final text = raw.trim();
        final maxLength = spec.maxLength;
        if (maxLength != null && text.length > maxLength) {
          return SettingsChangeInvalid(key, '${spec.label}は$maxLength文字までです');
        }
        if (spec.kind == SettingKind.url && text.isNotEmpty) {
          final uri = Uri.tryParse(text);
          if (uri == null || !(uri.isScheme('http') || uri.isScheme('https')) || uri.host.isEmpty) {
            return SettingsChangeInvalid(key, '${spec.label}は http(s) のURLで指定してください');
          }
        }
        return SettingsChangeOk(spec, text);
    }
  }

  /// Reads the argument object of the `update_settings` tool call.
  ///
  /// `{"changes": [{"key": "thinking", "value": false}, ...]}` — the same key twice keeps the
  /// last value, so a model that repeats itself does not produce two cards.
  static SettingsPatchResult parse(Object? arguments) {
    if (arguments is! Map) return const SettingsPatchInvalid('引数がオブジェクトではありません');
    final raw = arguments['changes'];
    if (raw is! List) return const SettingsPatchInvalid('changes が配列ではありません');
    if (raw.isEmpty) return const SettingsPatchInvalid('変更が1つもありません');
    if (raw.length > maxChanges) {
      return const SettingsPatchInvalid('一度に変更できるのは$maxChanges件までです');
    }

    final byKey = <String, SettingsChangeOk>{};
    for (final item in raw) {
      if (item is! Map) return const SettingsPatchInvalid('changes の要素がオブジェクトではありません');
      final key = item['key'];
      if (key is! String) return const SettingsPatchInvalid('key がありません');
      switch (normalize(key, item['value'])) {
        case SettingsChangeInvalid(:final reason):
          return SettingsPatchInvalid(reason);
        case final SettingsChangeOk ok:
          byKey[ok.key] = ok;
      }
    }
    return SettingsPatch(byKey.values.toList());
  }

  static const maxChanges = 6;

  static SettingsChangeInvalid? _range(SettingSpec spec, num value) {
    final min = spec.min;
    final max = spec.max;
    if (min != null && value < min) return SettingsChangeInvalid(spec.key, '${spec.label}は$min以上にしてください');
    if (max != null && value > max) return SettingsChangeInvalid(spec.key, '${spec.label}は$max以下にしてください');
    return null;
  }

  static bool? _flag(Object? raw) {
    if (raw is bool) return raw;
    if (raw is String) {
      final text = raw.trim().toLowerCase();
      if (text == 'true') return true;
      if (text == 'false') return false;
    }
    return null;
  }

  static double? _number(Object? raw) {
    if (raw is num) return raw.toDouble();
    if (raw is String) return double.tryParse(raw.trim());
    return null;
  }

  /// The text `get_settings` returns: every setting the model may change, with its current value,
  /// its label and what the app accepts for it, so the model can answer questions about the app
  /// without guessing and can pick a legal value for a change.
  static String describe(Map<String, Object?> values) {
    final b = StringBuffer();
    for (final key in keys) {
      final spec = specs[key]!;
      final value = values[key];
      b
        ..write('- $key = ')
        ..write(_formatValue(value))
        ..write('  # ${spec.label}');
      if (spec.kind == SettingKind.choice) {
        final labels = [for (final c in spec.choices) '$c（${spec.choiceLabels[c] ?? c}）'];
        b.write('、選択肢: ${labels.join(' / ')}');
      }
      if (spec.min != null || spec.max != null) {
        b.write('、範囲: ${spec.min ?? ''}〜${spec.max ?? ''}');
      }
      if (spec.maxLength != null) b.write('、${spec.maxLength}文字まで');
      b.write('\n');
    }
    b.write('次はチャットからは読むことも変えることもできません：APIキー（検索のキーも）とGitHubトークンは端末の'
        '安全な領域にあり、${blocked.join('、')} はアプリの状態・アップデートの取得元・エラー報告の送り先だからです。');
    return b.toString();
  }

  /// The stored value as the model sees it (a choice by its name, not its label).
  static String _formatValue(Object? value) {
    if (value == null) return '（未設定）';
    if (value is bool) return value ? 'true' : 'false';
    if (value is String) return value.isEmpty ? '（空）' : value;
    return '$value';
  }
}

enum SettingKind { flag, whole, decimal, choice, text, url }

class SettingSpec {
  const SettingSpec({
    required this.key,
    required this.label,
    required this.kind,
    this.choices = const [],
    this.choiceLabels = const {},
    this.min,
    this.max,
    this.maxLength,
  });

  final String key;

  /// What the confirmation card calls it.
  final String label;
  final SettingKind kind;
  final List<String> choices;
  final Map<String, String> choiceLabels;
  final num? min;
  final num? max;
  final int? maxLength;

  /// How the value reads on the confirmation card.
  String format(Object? value) => switch (kind) {
        SettingKind.flag => value == true ? 'オン' : 'オフ',
        SettingKind.choice => choiceLabels[value] ?? '$value',
        SettingKind.text || SettingKind.url => value == null || '$value'.isEmpty ? '（空）' : '「$value」',
        SettingKind.whole || SettingKind.decimal => '$value',
      };
}

sealed class SettingsChangeResult {
  const SettingsChangeResult();
}

/// One accepted change, ready to show and to apply.
class SettingsChangeOk extends SettingsChangeResult {
  const SettingsChangeOk(this.spec, this.value);

  final SettingSpec spec;
  final Object value;

  String get key => spec.key;

  /// e.g. `思考プロセスを「オフ」にする`.
  String get description => '${spec.label}を${spec.format(value)}にする';
}

class SettingsChangeInvalid extends SettingsChangeResult {
  const SettingsChangeInvalid(this.key, this.reason);

  final String key;
  final String reason;
}

sealed class SettingsPatchResult {
  const SettingsPatchResult();
}

/// The whole call is accepted; [changes] has one entry per distinct key.
class SettingsPatch extends SettingsPatchResult {
  const SettingsPatch(this.changes);

  final List<SettingsChangeOk> changes;
}

class SettingsPatchInvalid extends SettingsPatchResult {
  const SettingsPatchInvalid(this.reason);

  final String reason;
}

/// A provider the model proposes to add from the chat (`add_provider`).
///
/// Only what is safe to take from a chat message: a name, the address and the model ids. Headers,
/// extra request fields and the API key are not part of it — the key is typed on the settings
/// screen, and a provider that already exists cannot be changed from here, so a message cannot
/// send an existing key to another address.
class ProviderDraft {
  const ProviderDraft({
    required this.name,
    required this.baseUrl,
    required this.models,
    this.supportsTools = true,
  });

  static const maxModels = 20;
  static const maxNameLength = 60;
  static const maxModelIdLength = 200;

  final String name;

  /// Everything before `/chat/completions`.
  final String baseUrl;
  final List<String> models;
  final bool supportsTools;

  /// The arguments of the `add_provider` call, also how the card is saved with a conversation.
  Map<String, Object?> toJson() => {
        'name': name,
        'base_url': baseUrl,
        'models': models,
        'tools': supportsTools,
      };

  /// What the confirmation card shows. The address is spelled out so the user can see where a key
  /// typed later would be sent.
  String get description =>
      'プロバイダ「$name」を追加する（URL: $baseUrl、モデル: ${models.join('、')}、'
      'ツール呼び出し: ${supportsTools ? 'あり' : 'なし'}）';

  /// Checks the arguments; the result is the draft or the reason it cannot be used.
  static (ProviderDraft?, String?) parse(Object? arguments) {
    if (arguments is! Map) return (null, '引数がオブジェクトではありません');

    final rawName = arguments['name'];
    if (rawName is! String) return (null, 'name がありません');
    final name = rawName.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (name.isEmpty) return (null, 'プロバイダの名前が空です');
    if (name.length > maxNameLength) return (null, 'プロバイダの名前は$maxNameLength文字までです');

    final rawUrl = arguments['base_url'];
    if (rawUrl is! String) return (null, 'base_url がありません');
    final uri = Uri.tryParse(rawUrl.trim());
    if (uri == null || !(uri.isScheme('http') || uri.isScheme('https')) || uri.host.isEmpty) {
      return (null, 'base_url は http(s) のURLで指定してください');
    }
    if (uri.userInfo.isNotEmpty || uri.hasQuery || uri.hasFragment) {
      return (null, 'base_url にユーザー情報・クエリ・フラグメントは入れられません（APIキーは詳細設定の「APIキー」の欄に入れます）');
    }
    var baseUrl = rawUrl.trim().replaceAll(RegExp(r'/+$'), '');
    // the app adds this itself; pasting the full endpoint is a common slip
    baseUrl = baseUrl.replaceFirst(RegExp(r'/chat/completions$'), '');

    final rawModels = arguments['models'];
    if (rawModels is! List || rawModels.isEmpty) return (null, 'models が空です');
    final models = <String>[];
    for (final item in rawModels) {
      if (item is! String) return (null, 'models の要素が文字列ではありません');
      final id = item.trim();
      if (id.isEmpty) return (null, 'models に空のモデル名があります');
      if (id.length > maxModelIdLength) return (null, 'モデル名は$maxModelIdLength文字までです');
      if (!models.contains(id)) models.add(id);
    }
    if (models.length > maxModels) return (null, '一度に追加できるモデルは$maxModels個までです');

    final tools = arguments['tools'];
    return (
      ProviderDraft(
        name: name,
        baseUrl: baseUrl,
        models: models,
        supportsTools: tools is bool ? tools : true,
      ),
      null,
    );
  }
}
