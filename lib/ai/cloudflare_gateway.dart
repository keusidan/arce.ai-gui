/// Cloudflare AI Gateway: one OpenAI-compatible address in front of many model providers (OpenAI, Anthropic,
/// Google, xAI, Workers AI ...), paid and logged through the user's Cloudflare account.
///
/// What is used here, from Cloudflare's documentation:
/// * The REST API's chat completions: `https://api.cloudflare.com/client/v4/accounts/{account_id}/ai/v1`
///   as the OpenAI base URL, a Cloudflare API token with the permission Account > Workers AI > Read in
///   `Authorization: Bearer`, and models named `author/model` (`openai/gpt-4.1`) or, for Workers AI,
///   `@cf/author/model`. Third-party models are billed through Unified Billing (credits loaded in the account).
///   https://developers.cloudflare.com/ai-gateway/usage/rest-api/
/// * The header `cf-aig-gateway-id` picks the gateway; Workers AI models need it, and `default` is the
///   gateway Cloudflare makes by itself on the first request.
///   https://developers.cloudflare.com/ai-gateway/get-started/
/// * `GET https://api.cloudflare.com/client/v4/user/tokens/verify` says whether a token is valid and active.
///   https://developers.cloudflare.com/fundamentals/api/get-started/create-token/
///
/// The REST API documents no list of models, so none is read: the user writes the model names.
abstract final class CloudflareGateway {
  static const label = 'Cloudflare AI Gateway';

  /// The header that names the gateway, and the gateway Cloudflare creates by itself.
  static const gatewayHeader = 'cf-aig-gateway-id';
  static const defaultGateway = 'default';

  /// Where a token is checked (the token itself; not whether it may use Workers AI).
  static final verifyUri = Uri.parse('https://api.cloudflare.com/client/v4/user/tokens/verify');

  /// Model names as the documentation writes them, for the hints of the screen.
  static const exampleModels = ['openai/gpt-4.1', 'anthropic/claude-sonnet-4', 'google/gemini-3-flash', '@cf/moonshotai/kimi-k2.6'];

  static final _base = RegExp(r'^https://api\.cloudflare\.com/client/v4/accounts/([A-Za-z0-9]+)/ai/v1/?$');

  /// The base URL of the account [accountId] (spaces around it are dropped).
  static String baseUrl(String accountId) => 'https://api.cloudflare.com/client/v4/accounts/${accountId.trim()}/ai/v1';

  /// Whether [accountId] can go into the address: letters and digits only (an account ID is a hex string).
  static bool isAccountId(String accountId) => RegExp(r'^[A-Za-z0-9]+$').hasMatch(accountId.trim());

  /// The account ID of a base URL that is this API's, or null for any other address.
  static String? accountOf(String baseUrl) => _base.firstMatch(baseUrl.trim())?.group(1);

  static bool isGateway(String baseUrl) => accountOf(baseUrl) != null;

  /// The gateway the headers name, or [defaultGateway] when they name none.
  static String gatewayOf(Map<String, String> headers) {
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == gatewayHeader && entry.value.trim().isNotEmpty) return entry.value.trim();
    }
    return defaultGateway;
  }

  /// [headers] with the gateway header set to [gateway] ([defaultGateway] when empty). It is always sent: Workers
  /// AI models refuse a request without it, and for the other models it only says which gateway logs the call.
  static Map<String, String> withGateway(Map<String, String> headers, String gateway) => {
        for (final entry in headers.entries)
          if (entry.key.toLowerCase() != gatewayHeader) entry.key: entry.value,
        gatewayHeader: gateway.trim().isEmpty ? defaultGateway : gateway.trim(),
      };

  /// What to tell the user when this API refused a request (401: the documentation says a token with only an
  /// AI Gateway permission gets it), added to the provider's own message; empty for any other status.
  static String refusedHint(int status) =>
      status == 401 ? 'Cloudflare の API トークンに、Account > Workers AI > Read の権限が要ります（AI Gateway の権限だけでは断られます）。' : '';

  /// Said when the model list is asked for: this API has none.
  static const noModelList = 'Cloudflare AI Gateway はモデル一覧を返しません。プロバイダの「モデル」→「追加」で、openai/gpt-4.1 や @cf/moonshotai/kimi-k2.6 のように名前を書いてください';
}
