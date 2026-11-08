import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_all/webview_all.dart';

import '../core/safe_url.dart';
import 'theme.dart';
import 'widgets.dart';

/// What shows a page inside the chat. The app asks for an address and a height and does not care what draws it:
/// WebView on every platform ([webview_all]: Android WebView, WKWebView, WebView2, WebKitGTK), and anything
/// else that can show an address may stand in for it by setting [EmbeddedPage.builder] (the tests do, and a
/// viewer of another kind would).
typedef EmbeddedPageBuilder = Widget Function(BuildContext context, Uri address, double height);

/// A page of the local preview server (`PreviewServer`: an address only the app knows, a sandboxed origin of its
/// own for the page) shown inside the chat.
///
/// The page may run scripts, but it can go nowhere else from here: a move to another address is refused and, when it
/// is a web address, opened in the browser instead (a link in a generated page comes from a model). Where the
/// WebView cannot start (WebView2 is not on the PC, WebKitGTK is not installed), the card says so and offers the
/// browser, which shows the same page.
class EmbeddedPage extends StatefulWidget {
  const EmbeddedPage({super.key, required this.address, required this.height});

  final Uri address;
  final double height;

  /// Replaces the WebView (see [EmbeddedPageBuilder]); null uses it.
  static EmbeddedPageBuilder? builder;

  @override
  State<EmbeddedPage> createState() => _EmbeddedPageState();
}

class _EmbeddedPageState extends State<EmbeddedPage> {
  WebViewController? _controller;
  String? _problem;

  @override
  void initState() {
    super.initState();
    if (EmbeddedPage.builder != null) return;
    try {
      _controller = _start(widget.address);
    } catch (e) {
      _problem = '$e';
    }
  }

  /// In the system browser, when it is a web address (a link comes from a model or a page it wrote).
  static void _openOutside(String url) {
    final uri = safeWebUri(url);
    if (uri != null) launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  WebViewController _start(Uri address) {
    final controller = WebViewController();
    // the settings below are not all implemented on every platform: one that is not must not stop the page
    Future<void> optional(Future<void> Function() call) async {
      try {
        await call();
      } catch (_) {}
    }

    optional(() => controller.setJavaScriptMode(JavaScriptMode.unrestricted));
    optional(() => controller.setBackgroundColor(Colors.white));
    optional(
      () => controller.setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) {
            final uri = Uri.tryParse(request.url);
            if (uri != null && uri.scheme == address.scheme && uri.host == address.host && uri.port == address.port) {
              return NavigationDecision.navigate;
            }
            // not a move of this page: a link goes to the browser (web addresses only), anything else is dropped
            _openOutside(request.url);
            return NavigationDecision.prevent;
          },
          onWebResourceError: (error) {
            if (error.isForMainFrame ?? true) {
              if (mounted) setState(() => _problem = error.description);
            }
          },
        ),
      ),
    );
    optional(() => controller.loadRequest(address));
    return controller;
  }

  @override
  Widget build(BuildContext context) {
    final override = EmbeddedPage.builder;
    if (override != null) return override(context, widget.address, widget.height);
    final c = context.c;
    final controller = _controller;
    if (controller == null || _problem != null) {
      return Container(
        height: widget.height,
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        alignment: Alignment.center,
        color: c.surface3,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(
            'このアプリの中では表示できませんでした${_problem == null ? '' : '（$_problem）'}',
            textAlign: TextAlign.center,
            style: ts(context, 11, color: c.muted, height: 1.5),
          ),
          const SizedBox(height: 10),
          SoftButton(label: 'ブラウザで開く', svg: null, onTap: () => _openOutside(widget.address.toString())),
        ]),
      );
    }
    return SizedBox(height: widget.height, width: double.infinity, child: WebViewWidget(controller: controller));
  }
}
