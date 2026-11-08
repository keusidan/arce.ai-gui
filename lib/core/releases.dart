import 'dart:convert';

/// Semantic version "1.2.3" with an optional "-suffix"; a suffix sorts before the plain release.
class Version implements Comparable<Version> {
  const Version(this.major, this.minor, this.patch, [this.suffix = '']);

  final int major;
  final int minor;
  final int patch;
  final String suffix;

  static final _pattern = RegExp(r'^v?(\d+)\.(\d+)\.(\d+)(?:[-.+](.+))?$');

  static Version? parse(String text) {
    final m = _pattern.firstMatch(text.trim());
    if (m == null) return null;
    return Version(int.parse(m.group(1)!), int.parse(m.group(2)!), int.parse(m.group(3)!), m.group(4) ?? '');
  }

  @override
  int compareTo(Version other) {
    final byNumber = [major.compareTo(other.major), minor.compareTo(other.minor), patch.compareTo(other.patch)]
        .firstWhere((c) => c != 0, orElse: () => 0);
    if (byNumber != 0) return byNumber;
    if (suffix.isEmpty && other.suffix.isEmpty) return 0;
    if (suffix.isEmpty) return 1;
    if (other.suffix.isEmpty) return -1;
    return suffix.compareTo(other.suffix);
  }

  bool operator >(Version other) => compareTo(other) > 0;

  @override
  bool operator ==(Object other) => other is Version && compareTo(other) == 0;

  @override
  int get hashCode => Object.hash(major, minor, patch, suffix);

  @override
  String toString() => '$major.$minor.$patch${suffix.isEmpty ? '' : '-$suffix'}';
}

class ReleaseAsset {
  const ReleaseAsset({required this.id, required this.name, required this.sizeBytes});
  final int id;
  final String name;
  final int sizeBytes;
}

/// The platform builds. Every platform has its own release: [suffix] is what the release workflow appends
/// to the file name, [tagPrefix] what it puts before the version in the tag (Android keeps the plain
/// `v0.5.0`, because the earlier native app reads that; the others use `ios-v0.5.0` and so on).
enum UpdateTarget {
  android('-android.apk', ''),
  ios('-ios-unsigned.ipa', 'ios-'),
  windows('-windows-x64.zip', 'windows-'),
  macos('-macos.zip', 'macos-'),
  linux('-linux-x64.tar.gz', 'linux-');

  const UpdateTarget(this.suffix, this.tagPrefix);
  final String suffix;
  final String tagPrefix;
}

class Release {
  const Release({required this.tag, required this.version, required this.notes, required this.assets, this.htmlUrl});

  final String tag;
  final Version version;
  final String notes;
  final List<ReleaseAsset> assets;
  final String? htmlUrl;

  ReleaseAsset? assetFor(UpdateTarget target) {
    for (final a in assets) {
      if (a.name.endsWith(target.suffix)) return a;
    }
    return null;
  }

  /// The difference between the build [from] and [asset] (`<asset>.from-<version>.patch`, a bsdiff
  /// patch the Android release workflow writes for the last few builds), when there is one.
  ReleaseAsset? patchFor(ReleaseAsset asset, Version from) {
    for (final a in assets) {
      if (a.name == '${asset.name}.from-$from.patch') return a;
    }
    return null;
  }

  /// The `<asset>.sha256` file written next to every build by the release workflow.
  ReleaseAsset? checksumFor(ReleaseAsset asset) {
    for (final a in assets) {
      if (a.name == '${asset.name}.sha256') return a;
    }
    return null;
  }
}

abstract final class ReleaseParser {
  /// Parses one release of GitHub's API. A tag that does not start with [tagPrefix] belongs to another
  /// platform and gives null.
  static Release? parse(String json, {String tagPrefix = ''}) {
    final decoded = jsonDecode(json);
    return decoded is Map ? _fromMap(decoded, tagPrefix) : null;
  }

  /// The newest published release of [target] in GitHub's list of releases: the highest version among
  /// the tags with the platform's prefix that carry a file for it.
  static Release? latestFor(String listJson, UpdateTarget target) {
    final decoded = jsonDecode(listJson);
    if (decoded is! List) return null;
    Release? best;
    for (final item in decoded) {
      if (item is! Map || item['draft'] == true || item['prerelease'] == true) continue;
      final release = _fromMap(item, target.tagPrefix);
      if (release == null || release.assetFor(target) == null) continue;
      if (best == null || release.version > best.version) best = release;
    }
    return best;
  }

  static Release? _fromMap(Map<dynamic, dynamic> decoded, String tagPrefix) {
    final tag = decoded['tag_name'];
    if (tag is! String || !tag.startsWith(tagPrefix)) return null;
    final version = Version.parse(tag.substring(tagPrefix.length));
    if (version == null) return null;
    final assets = <ReleaseAsset>[
      for (final a in (decoded['assets'] as List? ?? const []))
        if (a is Map && a['id'] is int && a['name'] is String)
          ReleaseAsset(id: a['id'] as int, name: a['name'] as String, sizeBytes: (a['size'] as num?)?.toInt() ?? 0),
    ];
    return Release(
      tag: tag,
      version: version,
      notes: decoded['body'] as String? ?? '',
      assets: assets,
      htmlUrl: decoded['html_url'] as String?,
    );
  }

  /// `<hex>  file.apk` as written by sha256sum.
  static String? parseChecksum(String text) {
    final first = text.trim().split(RegExp(r'\s+')).first;
    return RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(first) ? first : null;
  }
}
